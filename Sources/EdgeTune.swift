import AppKit
import Carbon
import Foundation
import ServiceManagement

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
    private var cli: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "nowplaying-cli")
    }

    func read(player: MusicPlayer) -> Track? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty,
              let output = run(["get", "--json", "title", "artist", "album", "elapsedTime", "playbackRate", "bundleIdentifier"]),
              let data = output.data(using: .utf8),
              let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (info["bundleIdentifier"] as? String) == player.bundleID,
              let title = info["title"] as? String, !title.isEmpty else { return nil }
        let rate = (info["playbackRate"] as? NSNumber)?.doubleValue ?? 0
        return Track(source: player.name, title: title,
                     artist: info["artist"] as? String ?? "",
                     album: info["album"] as? String ?? "",
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

private final class LyricsService {
    func fetch(for track: Track, completion: @escaping ([LyricLine]) -> Void) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        var request = URLRequest(url: components.url!)
        request.setValue("EdgeTune/0.2 (open source macOS player)", forHTTPHeaderField: "User-Agent")
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
    private var settingsWindow: NSWindow?
    private var playerPicker: NSPopUpButton?
    private var loginCheckbox: NSButton?
    private var loginStatusLabel: NSTextField?
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
    private var selectedPlayer = MusicPlayer(rawValue: UserDefaults.standard.string(forKey: "selectedPlayer") ?? "") ?? .netease
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
        artistLabel = label("打开\(selectedPlayer.name)", x: 18, y: 56, width: 235, size: 10, color: .secondaryLabelColor)
        lyricLabel = label("♪  歌词会显示在这里", x: 18, y: 28, width: 280, size: 12, color: NSColor(calibratedRed: 0.48, green: 0.95, blue: 0.80, alpha: 1))
        [titleLabel!, artistLabel!, lyricLabel!].forEach { expandedContent.addSubview($0) }

        addButton("backward.fill", x: 210, y: 71, action: #selector(previous))
        addButton("playpause.fill", x: 244, y: 71, action: #selector(playPause))
        addButton("forward.fill", x: 278, y: 71, action: #selector(next))
        addButton("gearshape", x: 208, y: 23, action: #selector(showSettings))
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
        titleLabel.stringValue = current?.title ?? "没有正在播放的音乐"
        artistLabel.stringValue = current.map { "\($0.artist) · \($0.source)" } ?? "打开\(selectedPlayer.name)"
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

    @objc private func showSettings() {
        if settingsWindow == nil { createSettingsWindow() }
        refreshLoginStatus()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 225),
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
        settingsWindow = window
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
