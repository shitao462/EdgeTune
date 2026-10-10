import AppKit
import Carbon
import Foundation

private struct Track: Equatable {
    let source: String
    let title: String
    let artist: String
    let album: String
    let position: Double
    let playing: Bool
    let sampledAt: Date

    var identity: String { "\(source)|\(title)|\(artist)|\(album)" }
    var livePosition: Double { position + (playing ? Date().timeIntervalSince(sampledAt) : 0) }
}

private struct LyricLine {
    let time: Double
    let text: String
}

private final class MusicBridge {
    private let bundleID = "com.netease.163music"
    private var cli: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "nowplaying-cli")
    }

    func read() -> Track? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let output = run(["get", "--json", "title", "artist", "album", "elapsedTime", "playbackRate", "bundleIdentifier"]),
              let data = output.data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (info["bundleIdentifier"] as? String) == bundleID,
              let title = info["title"] as? String, !title.isEmpty else { return nil }
        let rate = (info["playbackRate"] as? NSNumber)?.doubleValue ?? 0
        return Track(source: "网易云音乐", title: title,
                     artist: info["artist"] as? String ?? "",
                     album: info["album"] as? String ?? "",
                     position: (info["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
                     playing: rate > 0, sampledAt: Date())
    }

    func control(_ command: String, source: String?) {
        guard source == "网易云音乐", ["togglePlayPause", "previous", "next"].contains(command) else { return }
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

private final class LyricsService {
    func fetch(for track: Track, completion: @escaping ([LyricLine]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        var request = URLRequest(url: components.url!)
        request.setValue("EdgeTune/0.1 (open source macOS player)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let records = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] ?? []
            let match = records.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            completion(Self.parse(match?["syncedLyrics"] as? String ?? ""))
        }.resume()
    }

    private static func parse(_ value: String) -> [LyricLine] {
        value.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<end].split(separator: ":")
            guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { return nil }
            let text = line[line.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : LyricLine(time: minutes * 60 + seconds, text: text)
        }.sorted { $0.time < $1.time }
    }
}

private final class HoverView: NSView {
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
    private var track: Track?
    private var lyricLines: [LyricLine] = []
    private var lyricTrackID = ""
    private var lyricsLoading = false
    private var readInFlight = false
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var root: HoverView!
    private var expandedContent: NSView!
    private var titleLabel: NSTextField!
    private var artistLabel: NSTextField!
    private var lyricLabel: NSTextField!
    private var collapsed = false
    private var pinned = false
    private var collapseWork: DispatchWorkItem?
    private var hotKey: EventHotKeyRef?
    private let width: CGFloat = 316
    private let height: CGFloat = 110
    private let sliver: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createMenu()
        installHotKey()
        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshTrack() }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.refreshLyric() }
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
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.12, alpha: 0.94).cgColor
        root.layer?.cornerRadius = 16
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        root.enter = { [weak self] in self?.collapseWork?.cancel() }
        root.exit = { [weak self] in self?.scheduleCollapse() }
        panel.contentView = root

        expandedContent = NSView(frame: root.bounds)
        root.addSubview(expandedContent)
        let accent = NSView(frame: NSRect(x: 0, y: 17, width: 3, height: 76))
        accent.wantsLayer = true
        accent.layer?.backgroundColor = NSColor(calibratedRed: 0.36, green: 0.91, blue: 0.75, alpha: 1).cgColor
        accent.layer?.cornerRadius = 2
        expandedContent.addSubview(accent)

        titleLabel = label("没有正在播放的音乐", x: 18, y: 77, width: 188, size: 13, color: .white, weight: .semibold)
        artistLabel = label("打开网易云音乐", x: 18, y: 56, width: 235, size: 10, color: .secondaryLabelColor)
        lyricLabel = label("♪  歌词会显示在这里", x: 18, y: 28, width: 280, size: 12, color: NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.80, alpha: 1))
        [titleLabel!, artistLabel!, lyricLabel!].forEach { expandedContent.addSubview($0) }

        addButton("backward.fill", x: 210, y: 71, action: #selector(previous))
        addButton("playpause.fill", x: 244, y: 71, action: #selector(playPause))
        addButton("forward.fill", x: 278, y: 71, action: #selector(next))
        addButton("pin", x: 242, y: 23, action: #selector(togglePin))
        addButton("chevron.right", x: 276, y: 23, action: #selector(collapseAction))

        let tab = NSButton(frame: NSRect(x: 1, y: 37, width: 22, height: 36))
        tab.title = "♫"
        tab.font = .systemFont(ofSize: 17, weight: .medium)
        tab.isBordered = false
        tab.contentTintColor = .white
        tab.target = self
        tab.action = #selector(expandAction)
        tab.identifier = NSUserInterfaceItemIdentifier("collapsedTab")
        tab.isHidden = true
        root.addSubview(tab)
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let current = self.bridge.read()
            DispatchQueue.main.async { self.readInFlight = false; self.apply(current) }
        }
    }

    private func apply(_ current: Track?) {
        track = current
        titleLabel.stringValue = current?.title ?? "没有正在播放的音乐"
        artistLabel.stringValue = current.map { "\($0.artist) · \($0.source)" } ?? "打开网易云音乐"
        if let current, current.identity != lyricTrackID {
            lyricTrackID = current.identity
            lyricLines = []
            lyricsLoading = true
            lyricLabel.stringValue = "正在查找同步歌词…"
            lyrics.fetch(for: current) { [weak self] lines in
                DispatchQueue.main.async {
                    guard let self, self.lyricTrackID == current.identity else { return }
                    self.lyricLines = lines
                    self.lyricsLoading = false
                    self.refreshLyric()
                }
            }
        } else if current == nil {
            lyricTrackID = ""
            lyricLines = []
            lyricsLoading = false
            lyricLabel.stringValue = "♪  歌词会显示在这里"
        }
    }

    private func refreshLyric() {
        guard let track else { return }
        guard !lyricsLoading else { return }
        guard !lyricLines.isEmpty else {
            lyricLabel.stringValue = "暂未找到同步歌词"
            return
        }
        let time = track.livePosition
        lyricLabel.stringValue = lyricLines.last(where: { $0.time <= time })?.text ?? lyricLines[0].text
    }

    private func scheduleCollapse() {
        guard !pinned, !collapsed else { return }
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCollapsed(true) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func setCollapsed(_ value: Bool) {
        guard value != collapsed else { return }
        collapsed = value
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let newWidth = value ? sliver : width
        let x = value ? screen.maxX - sliver : screen.maxX - width - 12
        panel.setFrame(NSRect(x: x, y: panel.frame.origin.y, width: newWidth, height: height), display: true, animate: true)
        root.frame = NSRect(x: 0, y: 0, width: newWidth, height: height)
        expandedContent.isHidden = value
        root.subviews.first(where: { $0.identifier?.rawValue == "collapsedTab" })?.isHidden = !value
    }

    @objc private func togglePanel() {
        if !panel.isVisible { panel.orderFrontRegardless(); setCollapsed(false) }
        else { setCollapsed(!collapsed) }
    }
    @objc private func expandAction() { setCollapsed(false); scheduleCollapse() }
    @objc private func collapseAction() { setCollapsed(true) }
    @objc private func togglePin() { pinned.toggle(); if !pinned { scheduleCollapse() } else { collapseWork?.cancel() } }
    @objc private func previous() { control("previous") }
    @objc private func playPause() { control("togglePlayPause") }
    @objc private func next() { control("next") }
    @objc private func quit() { NSApp.terminate(nil) }

    private func control(_ command: String) {
        let source = track?.source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.bridge.control(command, source: source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshTrack() }
        }
    }
}

private let app = NSApplication.shared
private let delegate = EdgeTuneApp()
app.delegate = delegate
app.run()
