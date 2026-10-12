import AppKit
import Carbon
import Foundation
import ServiceManagement
import QuartzCore
import ScreenCaptureKit
import AVFoundation

// Only an audio output is attached: no screen frames or recordings are retained.
private final class AudioPulse: NSObject, SCStreamOutput, SCStreamDelegate {
    private var capture: SCStream?
    private var source: String?
    private var generation = 0
    private var starting = false
    private var retryAfter = Date.distantPast
    private var needsPermission = false
    private let diagnostics = ProcessInfo.processInfo.environment["EDGETUNE_AUDIO_DIAGNOSTICS"] == "1"
    private var diagnosticTime = Date()
    private var diagnosticMin: Double = 1
    private var diagnosticMax: Double = 0
    private let audioQueue = DispatchQueue(label: "dev.opentune.edgetune.audio")
    private(set) var level: Double = 0
    private(set) var lastSample = Date.distantPast
    var statusChanged: ((String) -> Void)?

    func setSource(_ bundleID: String?) {
        if source == bundleID {
            guard bundleID != nil, capture == nil, !starting, Date() >= retryAfter else { return }
            if needsPermission && !CGPreflightScreenCaptureAccess() { return }
        }
        source = bundleID
        generation += 1
        let token = generation
        let old = capture
        capture = nil
        level = 0
        lastSample = .distantPast
        starting = bundleID != nil
        Task { @MainActor in
            if let old { try? await old.stopCapture() }
            guard self.generation == token, let bundleID else { return }
            do {
                self.statusChanged?("正在连接播放器音频…")
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard self.generation == token else { return }
                guard let display = content.displays.first,
                      let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                    self.starting = false
                    self.retryAfter = Date().addingTimeInterval(5)
                    self.statusChanged?("等待播放器音频，正在自动重连")
                    return
                }
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                self.capture = stream
                try await stream.startCapture()
                guard self.generation == token else { try? await stream.stopCapture(); return }
                self.starting = false
                self.needsPermission = false
                self.statusChanged?("已连接音频，边缘条跟随音乐强弱起伏")
                NSLog("EdgeTune audio: connected")
            } catch {
                guard self.generation == token else { return }
                self.capture = nil
                self.starting = false
                self.retryAfter = Date().addingTimeInterval(5)
                self.needsPermission = (error as NSError).code == -3801
                NSLog("EdgeTune audio: %@", error.localizedDescription)
                self.statusChanged?(self.needsPermission ? "请在系统设置允许录制权限，授权后自动重连" : "音频连接失败，正在自动重连")
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, let value = Self.measure(sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.capture === stream else { return }
            if self.lastSample == .distantPast { NSLog("EdgeTune audio: first sample, level %.3f", value) }
            self.level = value
            self.lastSample = Date()
            if self.diagnostics {
                self.diagnosticMin = min(self.diagnosticMin, value)
                self.diagnosticMax = max(self.diagnosticMax, value)
                if self.lastSample.timeIntervalSince(self.diagnosticTime) >= 3 {
                    NSLog("EdgeTune audio: live level range %.3f...%.3f", self.diagnosticMin, self.diagnosticMax)
                    self.diagnosticTime = self.lastSample
                    self.diagnosticMin = 1
                    self.diagnosticMax = 0
                }
            }
        }
    }

    static func measure(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr,
              let channels = pcm.floatChannelData else { return nil }
        var energy: Double = 0
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<count {
                let sample = Double(format.isInterleaved ? channels[0][frame * pcm.stride + channel] : channels[channel][frame])
                energy += sample * sample
            }
        }
        let rms = sqrt(energy / Double(count * channelCount))
        return max(0, min(1, (20 * log10(max(rms, 0.00001)) + 55) / 45))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.capture === stream else { return }
            self.capture = nil
            self.starting = false
            self.retryAfter = Date().addingTimeInterval(5)
            self.level = 0
            self.lastSample = .distantPast
            self.statusChanged?("音频连接已中断，正在自动重连")
        }
    }
}

private enum MusicPlayer: String, CaseIterable {
    case netease
    case qqMusic
    case spotify
    case appleMusic

    var name: String {
        switch self {
        case .netease: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    var bundleID: String {
        switch self {
        case .netease: return "com.netease.163music"
        case .qqMusic: return "com.tencent.QQMusicMac"
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }
}

private struct Track: Equatable {
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool
    let sampledAt: Date

    var identity: String { "\(source)|\(title)|\(artist)|\(album)" }
    var livePosition: Double { position + (playing ? Date().timeIntervalSince(sampledAt) : 0) }
}

private struct LyricLine {
    let time: Double
    let text: String
    var translation: String? = nil
}

private final class MusicBridge {
    private var cli: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "nowplaying-cli")
    }

    func read(player: MusicPlayer) -> Track? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty,
              let output = run(["get", "--json", "title", "artist", "album", "duration", "elapsedTime", "playbackRate", "bundleIdentifier"]),
              let data = output.data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (info["bundleIdentifier"] as? String) == player.bundleID,
              let title = info["title"] as? String, !title.isEmpty else { return nil }
        let rate = (info["playbackRate"] as? NSNumber)?.doubleValue ?? 0
        return Track(source: player.name, title: title,
                     artist: info["artist"] as? String ?? "",
                     album: info["album"] as? String ?? "",
                     duration: (info["duration"] as? NSNumber)?.doubleValue ?? 0,
                     position: (info["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
                     playing: rate > 0, sampledAt: Date())
    }

    func control(_ command: String, player: MusicPlayer) {
        guard ["togglePlayPause", "previous", "next"].contains(command), read(player: player) != nil else { return }
        _ = run([command])
    }

    private func run(_ arguments: [String]) -> String? {
        guard let cli else { return nil }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        } catch { return nil }
    }
}

private struct LyricsResult {
    var lines: [LyricLine] = []
    var instrumental = false
}

private final class LyricsService {
    func fetch(for track: Track, completion: @escaping (LyricsResult) -> Void) {
        if track.source == MusicPlayer.netease.name {
            fetchNetEase(for: track) { result in
                if let result { completion(result) }
                else { self.fetchLRCLIB(for: track, completion: completion) }
            }
        } else if track.source == MusicPlayer.qqMusic.name {
            fetchQQMusic(for: track) { result in
                if let result { completion(result) }
                else { self.fetchLRCLIB(for: track, completion: completion) }
            }
        } else {
            fetchLRCLIB(for: track, completion: completion)
        }
    }

    private func fetchNetEase(for track: Track, completion: @escaping (LyricsResult?) -> Void) {
        request(url: "https://music.163.com/api/search/get/web", query: [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "20")
        ]) { object in
            let songs = ((object as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
            guard let id = Self.netEaseSongID(songs, for: track) else { completion(nil); return }
            self.request(url: "https://music.163.com/api/song/lyric", query: [
                URLQueryItem(name: "id", value: String(id)), URLQueryItem(name: "lv", value: "-1"),
                URLQueryItem(name: "tv", value: "-1"), URLQueryItem(name: "kv", value: "-1")
            ]) { object in
                completion((object as? [String: Any]).flatMap(Self.netEaseLyrics))
            }
        }
    }

    private func fetchQQMusic(for track: Track, completion: @escaping (LyricsResult?) -> Void) {
        let payload: [String: Any] = ["comm": ["ct": 19, "cv": 1859], "req": [
            "module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop",
            "param": ["query": "\(track.title) \(track.artist)", "num_per_page": 20, "page_num": 1, "search_type": 0]
        ]]
        request(url: "https://u.y.qq.com/cgi-bin/musicu.fcg", query: [], body: payload) { object in
            guard let root = object as? [String: Any], (root["code"] as? Int) == 0,
                  let req = root["req"] as? [String: Any], (req["code"] as? Int) == 0 else { completion(nil); return }
            let data = req["data"] as? [String: Any]
            let body = data?["body"] as? [String: Any]
            let songs = (body?["song"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            guard let mid = Self.qqSongMID(songs, for: track) else { completion(nil); return }
            self.request(url: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", query: [
                URLQueryItem(name: "songmid", value: mid), URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "nobase64", value: "1")
            ]) { object in
                completion((object as? [String: Any]).flatMap(Self.qqLyrics))
            }
        }
    }

    static func qqSongMID(_ songs: [[String: Any]], for track: Track) -> String? {
        let records: [[String: Any]] = songs.enumerated().map { index, song in
            ["id": index, "name": song["name"] as? String ?? "", "artists": song["singer"] as? [[String: Any]] ?? [],
             "album": song["album"] as? [String: Any] ?? [:],
             "duration": ((song["interval"] as? NSNumber)?.doubleValue ?? 0) * 1000]
        }
        guard let index = netEaseSongID(records, for: track), let mid = songs[index]["mid"] as? String, !mid.isEmpty else { return nil }
        return mid
    }

    static func qqLyrics(_ object: [String: Any]) -> LyricsResult? {
        guard (object["code"] as? Int) == 0, (object["retcode"] as? Int ?? 0) == 0 else { return nil }
        func decoded(_ value: String) -> String {
            var text = value
            if !text.contains("["), let bytes = Data(base64Encoded: text), let raw = String(data: bytes, encoding: .utf8) { text = raw }
            let numeric = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
            let ns = text as NSString
            for match in numeric.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let token = ns.substring(with: match.range(at: 1))
                let number = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: text) { text.replaceSubrange(range, with: String(scalar)) }
            }
            for (entity, replacement) in [("&apos;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
            return text
        }
        // Missing or restricted lyrics are not evidence that a song is instrumental.
        return netEaseLyrics(["lrc": ["lyric": decoded(object["lyric"] as? String ?? "")],
                              "tlyric": ["lyric": decoded(object["trans"] as? String ?? "")]])
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func netEaseSongID(_ songs: [[String: Any]], for track: Track) -> Int? {
        let matches = songs.filter { song in
            let artists = (song["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let artist = normalized(track.artist)
            let artistMatches = !artist.isEmpty && (artists.contains { normalized($0) == artist } ||
                ["/", ",", " & ", "、"].contains { normalized(artists.joined(separator: $0)) == artist })
            let duration = (song["duration"] as? NSNumber)?.doubleValue ?? 0
            return normalized(song["name"] as? String ?? "") == normalized(track.title) && artistMatches &&
                track.duration > 0 && abs(duration / 1000 - track.duration) <= 2
        }
        let albumMatches = matches.filter { !track.album.isEmpty &&
            normalized(($0["album"] as? [String: Any])?["name"] as? String ?? "") == normalized(track.album) }
        let candidates = albumMatches.isEmpty ? matches : albumMatches
        // Ambiguous versions use the fallback rather than silently picking the first search hit.
        guard candidates.count == 1 else { return nil }
        return (candidates[0]["id"] as? NSNumber)?.intValue
    }

    static func netEaseLyrics(_ object: [String: Any]) -> LyricsResult? {
        if (object["uncollected"] as? Bool) == true { return nil }
        let raw = (object["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let originals = parse(raw)
        if (object["nolyric"] as? Bool) == true && originals.isEmpty { return LyricsResult(instrumental: true) }
        if originals.contains(where: { $0.text == "纯音乐，请欣赏" || $0.text == "纯音乐，请欣赏。" }) {
            return LyricsResult(instrumental: true)
        }
        guard !originals.isEmpty else { return nil }
        let translations = parse((object["tlyric"] as? [String: Any])?["lyric"] as? String ?? "")
        let lines = originals.map { line -> LyricLine in
            var line = line
            if let translated = translations.min(by: { abs($0.time - line.time) < abs($1.time - line.time) }),
               abs(translated.time - line.time) <= 0.35, translated.text != line.text {
                line.translation = translated.text
            }
            return line
        }
        return LyricsResult(lines: lines)
    }

    private func fetchLRCLIB(for track: Track, completion: @escaping (LyricsResult) -> Void) {
        var query = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        if !track.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 && track.duration <= 3600 { query.append(URLQueryItem(name: "duration", value: String(track.duration))) }
        request(endpoint: "get", query: query) { object in
            if let record = object as? [String: Any] {
                let result = Self.resolve([record], for: track)
                if !result.lines.isEmpty || result.instrumental { completion(result); return }
            }
            // Search also finds records with incomplete album metadata.
            self.request(endpoint: "search", query: Array(query.prefix(2))) { object in
                completion(Self.resolve(object as? [[String: Any]] ?? [], for: track))
            }
        }
    }

    private func request(endpoint: String, query: [URLQueryItem], completion: @escaping (Any?) -> Void) {
        request(url: "https://lrclib.net/api/\(endpoint)", query: query, completion: completion)
    }

    private func request(url: String, query: [URLQueryItem], body: [String: Any]? = nil, completion: @escaping (Any?) -> Void) {
        var components = URLComponents(string: url)!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 12)
        request.setValue("EdgeTune/1.2 (open source macOS player)", forHTTPHeaderField: "User-Agent")
        if components.host == "music.163.com" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if components.host?.hasSuffix(".y.qq.com") == true { request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer") }
        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion(nil); return }
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { completion(nil); return }
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
    }

    static func resolve(_ records: [[String: Any]], for track: Track) -> LyricsResult {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let matches = records.filter {
            normalized($0["trackName"] as? String ?? "") == normalized(track.title) &&
            normalized($0["artistName"] as? String ?? "") == normalized(track.artist)
        }
        let precise = matches.filter {
            let albumMatches = !track.album.isEmpty && normalized($0["albumName"] as? String ?? "") == normalized(track.album)
            let durationMatches = track.duration > 0 && abs((($0["duration"] as? NSNumber)?.doubleValue ?? -10000) - track.duration) <= 2
            return albumMatches || durationMatches
        }
        let candidates = precise.isEmpty ? matches : precise
        for record in candidates {
            let lines = Self.parse(record["syncedLyrics"] as? String ?? "")
            if !lines.isEmpty { return LyricsResult(lines: lines) }
        }
        // Absence of lyrics is not evidence of an instrumental track.
        let instrumental = !precise.isEmpty && precise.allSatisfy {
            ($0["instrumental"] as? Bool) == true &&
            ($0["plainLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ($0["syncedLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return LyricsResult(instrumental: instrumental)
    }

    private static func parse(_ value: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
        let offsetRegex = try! NSRegularExpression(pattern: "\\[offset:([+-]?\\d+)\\]")
        let nsValue = value as NSString
        let offset = offsetRegex.firstMatch(in: value, range: NSRange(location: 0, length: nsValue.length))
            .flatMap { Double(nsValue.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        return value.split(separator: "\n").flatMap { raw -> [LyricLine] in
            let line = String(raw)
            let nsLine = line as NSString
            let stamps = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard let last = stamps.last, stamps.first?.range.location == 0 else { return [] }
            let text = nsLine.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            return stamps.compactMap { stamp in
                guard let minutes = Double(nsLine.substring(with: stamp.range(at: 1))),
                      let seconds = Double(nsLine.substring(with: stamp.range(at: 2))), seconds < 60 else { return nil }
                return LyricLine(time: max(0, minutes * 60 + seconds - offset), text: text)
            }
        }.sorted { $0.time < $1.time }
    }
}

private enum WindowTheme: String, CaseIterable {
    case dark, light, glass
    var name: String {
        switch self {
        case .dark: return "黑色"
        case .light: return "白色"
        case .glass: return "玻璃 · 毛玻璃效果"
        }
    }
    var background: NSColor {
        switch self {
        case .dark: return NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.12, alpha: 0.94)
        case .light: return NSColor(calibratedWhite: 0.98, alpha: 0.97)
        case .glass: return .clear
        }
    }
}

private enum MusicTheme: String, CaseIterable {
    case mint, blue, purple, pink, orange, ocean, aurora, sunset
    var name: String {
        switch self {
        case .mint: return "莹绿色"
        case .blue: return "天空蓝"
        case .purple: return "薰衣草紫"
        case .pink: return "樱花粉"
        case .orange: return "暖橙色"
        case .ocean: return "渐变 · 海洋蓝绿"
        case .aurora: return "渐变 · 极光蓝紫"
        case .sunset: return "渐变 · 日落粉橙"
        }
    }
    var colors: [NSColor] {
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        switch self {
        case .mint: return [color(0.36, 0.91, 0.75)]
        case .blue: return [color(0.35, 0.72, 1)]
        case .purple: return [color(0.75, 0.61, 1)]
        case .pink: return [color(1, 0.58, 0.76)]
        case .orange: return [color(1, 0.72, 0.38)]
        case .ocean: return [color(0.35, 0.72, 1), color(0.36, 0.91, 0.75)]
        case .aurora: return [color(0.35, 0.72, 1), color(0.75, 0.61, 1)]
        case .sunset: return [color(1, 0.58, 0.76), color(1, 0.72, 0.38)]
        }
    }
}

private final class HoverView: NSView {
    var edgeGradient: CAGradientLayer?
    var pulseScale: CGFloat = 1
    func updatePulseFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height * (0.5 + 0.5 * pulseScale)
        edgeGradient?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updatePulseFrame()
        CATransaction.commit()
    }
    var enter: (() -> Void)?
    var exit: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { enter?() }
    override func mouseExited(with event: NSEvent) { exit?() }
}

private final class EdgeTuneApp: NSObject, NSApplicationDelegate {
    private let bridge = MusicBridge()
    private let lyrics = LyricsService()
    private let audioPulse = AudioPulse()
    private var pulseEnabled = UserDefaults.standard.object(forKey: "pulseEnabled") as? Bool ?? true
    private var pulseCheckbox: NSButton?
    private var pulseStatusLabel: NSTextField?
    private var pulseStatus = "播放音乐时需允许系统音频录制"
    private var pulseScale: CGFloat = 1
    private var track: Track?
    private var lyricLines: [LyricLine] = []
    private var instrumental = false
    private var lyricTrackID = ""
    private var lyricsLoading = false
    private var readInFlight = false
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var playerPicker: NSPopUpButton?
    private var themePicker: NSPopUpButton?
    private var windowThemePicker: NSPopUpButton?
    private var selectedWindowTheme = WindowTheme(rawValue: UserDefaults.standard.string(forKey: "windowTheme") ?? "") ?? .dark
    private var glassView: NSVisualEffectView!
    private let accentGradient = CAGradientLayer()
    private let edgeGradient = CAGradientLayer()
    private var selectedTheme = MusicTheme(rawValue: UserDefaults.standard.string(forKey: "selectedTheme") ?? "") ?? .mint
    private var loginCheckbox: NSButton?
    private var loginStatusLabel: NSTextField?
    private var panel: NSPanel!
    private var root: HoverView!
    private var expandedContent: NSView!
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var lyricLabel: NSTextField!
    private var translationLabel: NSTextField!
    private var collapsed = false
    private var pinned = false
    private var collapseWork: DispatchWorkItem?
    private var edgeHoverStarted: Date?
    private var transitionID = 0
    private var transitioning = false
    private var hotKey: EventHotKeyRef?
    private var selectedPlayer = MusicPlayer(rawValue: UserDefaults.standard.string(forKey: "selectedPlayer") ?? "") ?? .netease
    private let width: CGFloat = 316
    private let height: CGFloat = 110
    private let sliver: CGFloat = 7
    private let hiddenHeight: CGFloat = 72

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createMenu()
        audioPulse.statusChanged = { [weak self] text in
            self?.pulseStatus = text
            self?.pulseStatusLabel?.stringValue = text
        }
        installHotKey()
        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateHover() }
        scheduleCollapse()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshTrack() }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.refreshLyric() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.animatePulse() }
        refreshTrack()
    }

    private func createPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(x: screen.maxX - width - 16, y: screen.midY + 70, width: width, height: height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        root = HoverView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.12, alpha: 0.94).cgColor
        root.layer?.cornerRadius = 16
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        edgeGradient.frame = root.bounds
        edgeGradient.opacity = 0
        edgeGradient.cornerRadius = 3.5
        edgeGradient.masksToBounds = true
        edgeGradient.startPoint = CGPoint(x: 0, y: 1)
        edgeGradient.endPoint = CGPoint(x: 0, y: 0)
        root.layer?.addSublayer(edgeGradient)
        root.edgeGradient = edgeGradient
        root.enter = { [weak self] in self?.cancelCollapse() }
        root.exit = { [weak self] in self?.scheduleCollapse() }
        panel.contentView = root

        glassView = NSVisualEffectView(frame: root.bounds)
        glassView.autoresizingMask = [.width, .height]
        glassView.material = .hudWindow
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.appearance = NSAppearance(named: .aqua)
        root.addSubview(glassView)

        expandedContent = NSView(frame: root.bounds)
        root.addSubview(expandedContent)
        let accent = NSView(frame: NSRect(x: 0, y: 17, width: 3, height: 76))
        accent.wantsLayer = true
        accentGradient.frame = accent.bounds
        accentGradient.startPoint = CGPoint(x: 0, y: 1)
        accentGradient.endPoint = CGPoint(x: 0, y: 0)
        accent.layer?.addSublayer(accentGradient)
        accent.layer?.masksToBounds = true
        accent.layer?.cornerRadius = 1.5
        accentGradient.cornerRadius = 1.5
        accentGradient.masksToBounds = true
        expandedContent.addSubview(accent)

        titleLabel = label("没有正在播放的音乐", x: 18, y: 77, width: 188, size: 13, color: .white, weight: .semibold)
        artistLabel = label("打开\(selectedPlayer.name)", x: 18, y: 56, width: 235, size: 10, color: .secondaryLabelColor)
        lyricLabel = label("♪  歌词会显示在这里", x: 18, y: 10, width: 178, size: 12, color: NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.80, alpha: 1))
        lyricLabel.frame.size.height = 36
        lyricLabel.maximumNumberOfLines = 2
        lyricLabel.lineBreakMode = .byWordWrapping
        lyricLabel.cell?.wraps = true
        lyricLabel.cell?.isScrollable = false
        translationLabel = label("", x: 18, y: 10, width: 178, size: 11, color: .secondaryLabelColor)
        translationLabel.frame.size.height = 18
        translationLabel.lineBreakMode = .byTruncatingTail
        translationLabel.isHidden = true
        [titleLabel!, artistLabel!, lyricLabel!, translationLabel!].forEach { expandedContent.addSubview($0) }

        addButton("backward.fill", x: 210, y: 71, action: #selector(previous))
        addButton("playpause.fill", x: 244, y: 71, action: #selector(playPause))
        addButton("forward.fill", x: 278, y: 71, action: #selector(next))
        addButton("gearshape", x: 208, y: 23, action: #selector(showSettings))
        addButton("pin", x: 242, y: 23, action: #selector(togglePin))
        addButton("chevron.right", x: 276, y: 23, action: #selector(collapseAction))

        applyTheme()
        applyWindowTheme()

    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: size + 7)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func addButton(_ symbol: String, x: CGFloat, y: CGFloat, action: Selector) {
        let button = NSButton(frame: NSRect(x: x, y: y, width: 25, height: 24))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.target = self
        button.action = action
        expandedContent.addSubview(button)
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "EdgeTune")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 / 收起浮窗  ⌥⌘M", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "固定 / 自动收起", action: #selector(togglePin), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 EdgeTune", action: #selector(quit), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func installHotKey() {
        let id = EventHotKeyID(signature: OSType(0x4554554E), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<EdgeTuneApp>.fromOpaque(context).takeUnretainedValue().togglePanel()
            return noErr
        }, 1, &type, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), nil)
    }

    private func refreshTrack() {
        guard !readInFlight else { return }
        readInFlight = true
        let player = selectedPlayer
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let current = self.bridge.read(player: player)
            DispatchQueue.main.async {
                self.readInFlight = false
                if self.selectedPlayer == player { self.apply(current) }
                else { self.refreshTrack() }
            }
        }
    }

    private func apply(_ current: Track?) {
        track = current
        audioPulse.setSource(pulseEnabled && current?.playing == true ? selectedPlayer.bundleID : nil)
        titleLabel.stringValue = current?.title ?? "没有正在播放的音乐"
        artistLabel.stringValue = current.map { "\($0.artist) · \($0.source)" } ?? "打开\(selectedPlayer.name)"
        if let current, current.identity != lyricTrackID {
            lyricTrackID = current.identity
            lyricLines = []
            instrumental = false
            lyricsLoading = true
            resetTranslation()
            lyricLabel.stringValue = "正在查找同步歌词…"
            lyrics.fetch(for: current) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.lyricTrackID == current.identity else { return }
                    self.lyricLines = result.lines
                    self.instrumental = result.instrumental
                    self.lyricsLoading = false
                    self.refreshLyric()
                }
            }
        } else if current == nil {
            lyricTrackID = ""
            lyricLines = []
            instrumental = false
            lyricsLoading = false
            resetTranslation()
            lyricLabel.stringValue = "♪  歌词会显示在这里"
        }
    }

    private func resetTranslation() {
        translationLabel.isHidden = true
        translationLabel.stringValue = ""
        lyricLabel.frame = NSRect(x: 18, y: 10, width: 178, height: 36)
        lyricLabel.maximumNumberOfLines = 2
        lyricLabel.lineBreakMode = .byWordWrapping
        lyricLabel.cell?.wraps = true
    }

    private func refreshLyric() {
        guard let track else { return }
        guard !lyricsLoading else { return }
        resetTranslation()
        if instrumental { lyricLabel.stringValue = "纯音乐，请欣赏"; return }
        guard !lyricLines.isEmpty else {
            lyricLabel.stringValue = "暂未找到同步歌词"
            return
        }
        let time = track.livePosition
        let line = lyricLines.last(where: { $0.time <= time }) ?? lyricLines[0]
        lyricLabel.stringValue = line.text
        if let translation = line.translation, !translation.isEmpty {
            lyricLabel.frame = NSRect(x: 18, y: 28, width: 178, height: 18)
            lyricLabel.maximumNumberOfLines = 1
            lyricLabel.lineBreakMode = .byTruncatingTail
            lyricLabel.cell?.wraps = false
            translationLabel.stringValue = translation
            translationLabel.isHidden = false
        }
    }

    private func animatePulse() {
        let active = pulseEnabled && track?.playing == true && Date().timeIntervalSince(audioPulse.lastSample) < 0.4
        let target: CGFloat = active ? CGFloat(audioPulse.level) : 1
        pulseScale += (target - pulseScale) * (target > pulseScale ? 0.5 : 0.16)
        guard abs(root.pulseScale - pulseScale) > 0.001 else { return }
        root.pulseScale = pulseScale
        root.updatePulseFrame()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = 76 * (0.5 + 0.5 * pulseScale)
        accentGradient.frame = NSRect(x: 0, y: 0, width: 3, height: h)
        CATransaction.commit()
    }

    private func scheduleCollapse() {
        guard !pinned, !collapsed, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            guard !self.pinned, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.setCollapsed(true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func updateHover() {
        guard panel.isVisible, !transitioning else { return }
        let mouse = NSEvent.mouseLocation
        if !collapsed {
            if panel.frame.contains(mouse) { cancelCollapse() }
            else { scheduleCollapse() }
            return
        }
        let screen = panel.screen?.frame ?? NSScreen.main!.frame
        let trigger = NSRect(x: screen.maxX - 8, y: panel.frame.minY - 12,
                             width: 8, height: hiddenHeight + 24)
        guard trigger.contains(mouse) else { edgeHoverStarted = nil; return }
        if let started = edgeHoverStarted {
            if Date().timeIntervalSince(started) >= 0.2 { setCollapsed(false) }
        } else { edgeHoverStarted = Date() }
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed else { return }
        cancelCollapse()
        edgeHoverStarted = nil
        collapsed = value
        transitionID += 1
        let currentTransition = transitionID
        transitioning = true
        let screen = panel.screen?.frame ?? NSScreen.main!.frame
        let visible = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let newWidth = value ? sliver : width
        let newHeight = value ? hiddenHeight : height
        let x = value ? screen.maxX - sliver : screen.maxX - width - 12
        let y = min(max(panel.frame.midY - newHeight / 2, visible.minY), visible.maxY - newHeight)
        expandedContent.isHidden = false
        glassView.isHidden = selectedWindowTheme != .glass
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let duration = value ? 0.32 : 0.38
        if let layer = root.layer {
            let color = value ? NSColor.clear.cgColor : selectedWindowTheme.background.cgColor
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color
            fade.duration = duration
            fade.timingFunction = timing
            layer.backgroundColor = color
            layer.add(fade, forKey: "edgeColor")
            let rounding = CABasicAnimation(keyPath: "cornerRadius")
            rounding.fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
            rounding.toValue = value ? sliver / 2 : 16
            rounding.duration = duration
            rounding.timingFunction = timing
            layer.cornerRadius = value ? sliver / 2 : 16
            layer.add(rounding, forKey: "edgeRounding")
            layer.borderWidth = value ? 0 : 1
        }
        let edgeFade = CABasicAnimation(keyPath: "opacity")
        edgeFade.fromValue = edgeGradient.presentation()?.opacity ?? edgeGradient.opacity
        edgeFade.toValue = value ? 0.8 : 0
        edgeFade.duration = duration
        edgeFade.timingFunction = timing
        edgeGradient.opacity = value ? 0.8 : 0
        edgeGradient.add(edgeFade, forKey: "edgeFade")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            expandedContent.animator().alphaValue = value ? 0 : 1
            glassView.animator().alphaValue = value ? 0 : 1
            panel.animator().setFrame(NSRect(x: x, y: y, width: newWidth, height: newHeight), display: true)
        } completionHandler: { [weak self] in
            guard let self, self.transitionID == currentTransition else { return }
            self.transitioning = false
            self.expandedContent.isHidden = value
            self.glassView.isHidden = value || self.selectedWindowTheme != .glass
            self.panel.hasShadow = !value
            if !value { self.scheduleCollapse() }
        }
    }

    @objc private func togglePanel() {
        if !panel.isVisible { panel.orderFrontRegardless(); setCollapsed(false) }
        else { setCollapsed(!collapsed) }
    }
    @objc private func expandAction() { setCollapsed(false); scheduleCollapse() }
    @objc private func collapseAction() { setCollapsed(true) }
    @objc private func togglePin() { pinned.toggle(); if !pinned { scheduleCollapse() } else { cancelCollapse() } }
    @objc private func previous() { control("previous") }
    @objc private func playPause() { control("togglePlayPause") }
    @objc private func next() { control("next") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        if settingsWindow == nil { createSettingsWindow() }
        refreshLoginStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 525),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EdgeTune 设置"
        window.center()
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content

        let playerTitle = label("控制的音乐软件", x: 24, y: 175, width: 190, size: 13, color: .labelColor, weight: .semibold)
        content.addSubview(playerTitle)
        let picker = NSPopUpButton(frame: NSRect(x: 22, y: 136, width: 346, height: 30), pullsDown: false)
        MusicPlayer.allCases.forEach { picker.addItem(withTitle: $0.name) }
        picker.selectItem(at: MusicPlayer.allCases.firstIndex(of: selectedPlayer) ?? 0)
        picker.target = self
        picker.action = #selector(changePlayer)
        content.addSubview(picker)
        playerPicker = picker

        let hint = label("仅控制所选播放器在系统中显示的当前歌曲。", x: 24, y: 110, width: 340, size: 11, color: .secondaryLabelColor)
        content.addSubview(hint)
        let checkbox = NSButton(checkboxWithTitle: "登录 Mac 后自动启动 EdgeTune", target: self, action: #selector(changeLaunchAtLogin))
        checkbox.frame = NSRect(x: 22, y: 62, width: 345, height: 25)
        content.addSubview(checkbox)
        loginCheckbox = checkbox
        let status = label("", x: 24, y: 34, width: 340, size: 11, color: .secondaryLabelColor)
        content.addSubview(status)
        loginStatusLabel = status
        for view in content.subviews { view.frame.origin.y += 100 }
        content.addSubview(label("主题色", x: 24, y: 86, width: 190, size: 13, color: .labelColor, weight: .semibold))
        let themes = NSPopUpButton(frame: NSRect(x: 22, y: 47, width: 346, height: 30), pullsDown: false)
        for theme in MusicTheme.allCases {
            themes.addItem(withTitle: theme.name)
            let swatch = NSImage(size: NSSize(width: 28, height: 14), flipped: false) { rect in
                let colors = theme.colors.count == 1 ? [theme.colors[0], theme.colors[0]] : theme.colors
                NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4), angle: 0)
                return true
            }
            themes.lastItem?.image = swatch
        }
        themes.selectItem(at: MusicTheme.allCases.firstIndex(of: selectedTheme) ?? 0)
        themes.target = self
        themes.action = #selector(changeTheme)
        content.addSubview(themes)
        themePicker = themes
        content.addSubview(label("立即生效，边缘与歌词同步换色。", x: 24, y: 20, width: 340, size: 11, color: .secondaryLabelColor))
        for view in content.subviews { view.frame.origin.y += 100 }
        content.addSubview(label("窗口主题", x: 24, y: 86, width: 190, size: 13, color: .labelColor, weight: .semibold))
        let surfaces = NSPopUpButton(frame: NSRect(x: 22, y: 47, width: 346, height: 30), pullsDown: false)
        WindowTheme.allCases.forEach { surfaces.addItem(withTitle: $0.name) }
        surfaces.selectItem(at: WindowTheme.allCases.firstIndex(of: selectedWindowTheme) ?? 0)
        surfaces.target = self
        surfaces.action = #selector(changeWindowTheme)
        content.addSubview(surfaces)
        windowThemePicker = surfaces
        content.addSubview(label("玻璃效果会模糊透出窗口后面的内容。", x: 24, y: 20, width: 340, size: 11, color: .secondaryLabelColor))
        for view in content.subviews { view.frame.origin.y += 100 }
        let pulse = NSButton(checkboxWithTitle: "边缘条跟随音乐节奏", target: self, action: #selector(changePulse))
        pulse.frame = NSRect(x: 22, y: 72, width: 346, height: 26)
        pulse.state = pulseEnabled ? .on : .off
        content.addSubview(pulse)
        pulseCheckbox = pulse
        let pulseHint = label(pulseStatus, x: 24, y: 44, width: 342, size: 10, color: .secondaryLabelColor)
        content.addSubview(pulseHint)
        pulseStatusLabel = pulseHint
        content.addSubview(label("仅在本机分析播放器音量，不保存音频。", x: 24, y: 20, width: 342, size: 11, color: .secondaryLabelColor))
        settingsWindow = window
    }

    private func applyTheme() {
        let colors = selectedTheme.colors
        let stops = (colors.count == 1 ? [colors[0], colors[0]] : colors).map { $0.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentGradient.colors = stops
        edgeGradient.colors = stops
        CATransaction.commit()
        lyricLabel.textColor = selectedWindowTheme == .dark ? colors[0] : colors[0].blended(withFraction: 0.42, of: .black)
        translationLabel.textColor = selectedWindowTheme == .dark ? NSColor(calibratedWhite: 0.82, alpha: 1) : NSColor(calibratedWhite: 0.32, alpha: 1)
    }

    @objc private func changePulse() {
        pulseEnabled = pulseCheckbox?.state == .on
        UserDefaults.standard.set(pulseEnabled, forKey: "pulseEnabled")
        audioPulse.setSource(pulseEnabled && track?.playing == true ? selectedPlayer.bundleID : nil)
        if !pulseEnabled {
            pulseStatus = "节奏动画已关闭"
            pulseStatusLabel?.stringValue = pulseStatus
        } else if track?.playing != true {
            pulseStatus = "等待所选播放器开始播放"
            pulseStatusLabel?.stringValue = pulseStatus
        }
    }

    private func applyWindowTheme() {
        let dark = selectedWindowTheme == .dark
        root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.layer?.removeAnimation(forKey: "edgeColor")
        root.layer?.backgroundColor = collapsed ? NSColor.clear.cgColor : selectedWindowTheme.background.cgColor
        root.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.14)).cgColor
        glassView.isHidden = collapsed || selectedWindowTheme != .glass
        glassView.alphaValue = collapsed ? 0 : 1
        titleLabel.textColor = dark ? .white : NSColor(calibratedWhite: 0.1, alpha: 1)
        artistLabel.textColor = dark ? NSColor(calibratedWhite: 0.72, alpha: 1) : NSColor(calibratedWhite: 0.34, alpha: 1)
        for case let button as NSButton in expandedContent.subviews {
            button.contentTintColor = dark ? NSColor.white.withAlphaComponent(0.85) : NSColor(calibratedWhite: 0.16, alpha: 1)
        }
        applyTheme()
    }

    @objc private func changeWindowTheme() {
        guard let picker = windowThemePicker, WindowTheme.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        selectedWindowTheme = WindowTheme.allCases[picker.indexOfSelectedItem]
        UserDefaults.standard.set(selectedWindowTheme.rawValue, forKey: "windowTheme")
        applyWindowTheme()
    }

    @objc private func changeTheme() {
        guard let picker = themePicker, MusicTheme.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        selectedTheme = MusicTheme.allCases[picker.indexOfSelectedItem]
        UserDefaults.standard.set(selectedTheme.rawValue, forKey: "selectedTheme")
        applyTheme()
    }

    @objc private func changePlayer() {
        guard let picker = playerPicker, MusicPlayer.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        selectedPlayer = MusicPlayer.allCases[picker.indexOfSelectedItem]
        UserDefaults.standard.set(selectedPlayer.rawValue, forKey: "selectedPlayer")
        apply(nil)
        refreshTrack()
    }

    private func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginCheckbox?.state = .on
            loginStatusLabel?.stringValue = "已开启开机启动"
        case .requiresApproval:
            loginCheckbox?.state = .on
            loginStatusLabel?.stringValue = "请在系统设置的登录项中允许 EdgeTune"
        default:
            loginCheckbox?.state = .off
            loginStatusLabel?.stringValue = "当前不会开机启动"
        }
    }

    @objc private func changeLaunchAtLogin() {
        do {
            if loginCheckbox?.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            let alert = NSAlert()
            alert.messageText = "无法更改开机启动设置"
            alert.informativeText = error.localizedDescription
            if let settingsWindow { alert.beginSheetModal(for: settingsWindow) }
            else { alert.runModal() }
        }
    }

    private func control(_ command: String) {
        let player = selectedPlayer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.bridge.control(command, player: player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshTrack() }
        }
    }
}

private let app = NSApplication.shared
private let delegate = EdgeTuneApp()
app.delegate = delegate
app.run()
