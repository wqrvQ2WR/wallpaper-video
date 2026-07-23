import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import CryptoKit
import WebKit
import SwiftTerm

// MARK: - Desktop-level window that hosts the video

final class DesktopWindow: NSWindow {
    // Only allow key/main status while an interactive wallpaper (HTML/terminal)
    // is up, so the terminal can receive keyboard input; a plain video
    // wallpaper stays non-focusable and never steals focus.
    var interactive = false
    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { interactive }
}

final class PlayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

// Desktop-level windows never become key, so every click arrives as a
// "first mouse" — accept it or clicks would be swallowed
final class WallpaperWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Terminal wallpaper: same first-mouse handling, plus activate the (accessory)
// app on click so keystrokes route to the shell
final class WallpaperTerminalView: LocalProcessTerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

enum TranscodeError: Error {
    case ffmpegNotFound
    case ffmpegFailed
}

// MARK: - Playlist model

struct PlaylistItem: Codable {
    let path: String
    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Interval options

enum SwitchInterval: Int, CaseIterable {
    case off     = 0
    case min1    = 60
    case min5    = 300
    case min15   = 900
    case min30   = 1800
    case hour1   = 3600

    var label: String {
        switch self {
        case .off:    "끄기 (한곡만)"
        case .min1:   "1분"
        case .min5:   "5분"
        case .min15:  "15분"
        case .min30:  "30분"
        case .hour1:  "1시간"
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: DesktopWindow!
    private var playerView: PlayerView!
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var isPlaying = false
    private var webView: WKWebView?
    private var showingHTML = false
    private var htmlInteraction = true
    private var terminalView: WallpaperTerminalView?
    private var showingTerminal = false
    private var terminalModeEnabled = false
    private var shellRunning = false

    private let playlistKey = "WallpaperPlaylist"
    private let currentIndexKey = "WallpaperCurrentIndex"
    private let intervalKey = "WallpaperSwitchInterval"
    private let shuffleKey = "WallpaperShuffle"
    private let htmlInteractionKey = "WallpaperHTMLInteraction"
    private let muteKey = "WallpaperMuted"
    private let terminalModeKey = "WallpaperTerminalMode"

    private var playlist: [PlaylistItem] = []
    private var currentIndex = 0
    private var switchInterval: SwitchInterval = .off
    private var shuffle = false
    private var isMuted = true
    private var switchTimer: Timer?

    private var shuffledOrder: [Int] = []
    private var shuffleIndex = 0

    // Menu item references for dynamic updates
    private weak var playlistMenu: NSMenu?
    private weak var intervalMenu: NSMenu?
    private weak var toggleMenuItem: NSMenuItem?
    private weak var nowPlayingItem: NSMenuItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadState()
        setupStatusItem()
        setupDesktopWindow()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if terminalModeEnabled {
            setTerminalMode(true)
        } else if !playlist.isEmpty {
            loadVideo(at: currentIndex)
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: playlistKey),
           let items = try? JSONDecoder().decode([PlaylistItem].self, from: data) {
            playlist = items
        }
        currentIndex = UserDefaults.standard.integer(forKey: currentIndexKey)
        if currentIndex >= playlist.count { currentIndex = 0 }
        let raw = UserDefaults.standard.integer(forKey: intervalKey)
        switchInterval = SwitchInterval(rawValue: raw) ?? .off
        shuffle = UserDefaults.standard.bool(forKey: shuffleKey)
        if UserDefaults.standard.object(forKey: htmlInteractionKey) != nil {
            htmlInteraction = UserDefaults.standard.bool(forKey: htmlInteractionKey)
        }
        if UserDefaults.standard.object(forKey: muteKey) != nil {
            isMuted = UserDefaults.standard.bool(forKey: muteKey)
        }
        terminalModeEnabled = UserDefaults.standard.bool(forKey: terminalModeKey)
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(playlist) {
            UserDefaults.standard.set(data, forKey: playlistKey)
        }
        UserDefaults.standard.set(currentIndex, forKey: currentIndexKey)
    }

    private func saveInterval() {
        UserDefaults.standard.set(switchInterval.rawValue, forKey: intervalKey)
    }

    private func saveShuffle() {
        UserDefaults.standard.set(shuffle, forKey: shuffleKey)
    }

    private func saveMute() {
        UserDefaults.standard.set(isMuted, forKey: muteKey)
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let icon = NSImage(contentsOfFile: iconPath) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Wallpaper Video")
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Now playing
        let nowPlaying = NSMenuItem(title: nowPlayingText(), action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        nowPlayingItem = nowPlaying
        menu.addItem(nowPlaying)
        menu.addItem(NSMenuItem.separator())

        // Interval submenu
        let intervalItem = NSMenuItem(title: "⏱ 전환 간격", action: nil, keyEquivalent: "")
        let intervalSub = NSMenu()
        intervalSub.autoenablesItems = false
        for interval in SwitchInterval.allCases {
            let item = NSMenuItem(title: interval.label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.representedObject = interval.rawValue
            item.state = interval == switchInterval ? .on : .off
            item.target = self
            intervalSub.addItem(item)
        }
        intervalItem.submenu = intervalSub
        intervalMenu = intervalSub
        menu.addItem(intervalItem)

        // Shuffle toggle
        let shuffleItem = NSMenuItem(title: shuffle ? "🔀 셔플 켜짐" : "🔀 셔플 꺼짐", action: #selector(toggleShuffle), keyEquivalent: "")
        shuffleItem.target = self
        menu.addItem(shuffleItem)

        // HTML interaction toggle
        let interactionItem = NSMenuItem(title: "🖱 HTML 상호작용", action: #selector(toggleHTMLInteraction), keyEquivalent: "")
        interactionItem.target = self
        interactionItem.state = htmlInteraction ? .on : .off
        menu.addItem(interactionItem)

        // Mute toggle
        let muteItem = NSMenuItem(title: isMuted ? "🔇 음소거 켜짐" : "🔊 소리 켜짐", action: #selector(toggleMute), keyEquivalent: "m")
        muteItem.target = self
        menu.addItem(muteItem)

        // Terminal wallpaper toggle
        let terminalItem = NSMenuItem(title: "🖥 터미널 배경화면", action: #selector(toggleTerminal), keyEquivalent: "t")
        terminalItem.target = self
        terminalItem.state = terminalModeEnabled ? .on : .off
        menu.addItem(terminalItem)

        menu.addItem(NSMenuItem.separator())

        // Playlist header + items
        let playlistHeader = NSMenuItem(title: "📋 플레이리스트 (\(playlist.count))", action: nil, keyEquivalent: "")
        playlistHeader.isEnabled = false
        menu.addItem(playlistHeader)

        let playlistSub = NSMenu()
        playlistSub.autoenablesItems = false
        if playlist.isEmpty {
            let emptyItem = NSMenuItem(title: "   (비어있음)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            playlistSub.addItem(emptyItem)
        } else {
            for (i, item) in playlist.enumerated() {
                let title = i == currentIndex ? "▶ \(item.name)" : "  \(item.name)"
                let menuItem = NSMenuItem(title: title, action: #selector(selectPlaylistItem(_:)), keyEquivalent: "")
                menuItem.representedObject = i
                menuItem.target = self
                playlistSub.addItem(menuItem)
            }
        }
        playlistSub.addItem(NSMenuItem.separator())
        let addItem = NSMenuItem(title: "➕ 비디오/HTML 추가...", action: #selector(addVideo), keyEquivalent: "o")
        addItem.target = self
        playlistSub.addItem(addItem)
        let removeItem = NSMenuItem(title: "🗑 현재 곡 삭제", action: #selector(removeCurrent), keyEquivalent: "\u{8}")
        removeItem.target = self
        removeItem.isEnabled = !playlist.isEmpty
        playlistSub.addItem(removeItem)
        let clearItem = NSMenuItem(title: "🗑 전체 삭제", action: #selector(clearPlaylist), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = !playlist.isEmpty
        playlistSub.addItem(clearItem)

        let playlistMenuItem = NSMenuItem(title: "플레이리스트 편집", action: nil, keyEquivalent: "")
        playlistMenuItem.submenu = playlistSub
        playlistMenu = playlistSub
        menu.addItem(playlistMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Playback control
        let toggle = NSMenuItem(title: isPlaying ? "⏸ 일시정지" : "▶ 재생", action: #selector(togglePlayback), keyEquivalent: "p")
        toggle.target = self
        toggle.isEnabled = !showingHTML
        toggleMenuItem = toggle
        menu.addItem(toggle)

        let nextItem = NSMenuItem(title: "⏭ 다음 곡", action: #selector(nextTrack), keyEquivalent: "n")
        nextItem.target = self
        nextItem.isEnabled = playlist.count > 1
        menu.addItem(nextItem)

        menu.addItem(NSMenuItem.separator())

        // Login item
        let loginItem = NSMenuItem(title: "🔒 로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func rebuildMenu() {
        buildMenu()
    }

    private func nowPlayingText() -> String {
        if showingTerminal { return "🖥 터미널 배경화면" }
        guard !playlist.isEmpty else { return "🎬 선택된 영상 없음" }
        let name = playlist[currentIndex].name
        let total = playlist.count
        return "▶ \(name) (\(currentIndex+1)/\(total))"
    }

    // MARK: - Desktop window

    private func setupDesktopWindow() {
        guard let screen = NSScreen.main else { return }

        window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        let desktopLevel = CGWindowLevelForKey(.desktopWindow)
        window.level = NSWindow.Level(rawValue: Int(desktopLevel))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true // hover effects in HTML wallpapers
        window.hasShadow = false

        // Container holds playerView and webView as siblings so hiding one
        // never hides the other
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        playerView = PlayerView(frame: container.bounds)
        playerView.autoresizingMask = [.width, .height]
        container.addSubview(playerView)
        window.contentView = container

        window.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
    }

    // MARK: - Playlist management

    @objc private func addVideo() {
        let panel = NSOpenPanel()
        panel.title = "배경화면으로 사용할 비디오/HTML 선택"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var contentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .html]
        if let webmType = UTType(filenameExtension: "webm") {
            contentTypes.append(webmType)
        }
        panel.allowedContentTypes = contentTypes

        if panel.runModal() == .OK {
            let prevCount = playlist.count
            for url in panel.urls {
                if !playlist.contains(where: { $0.path == url.path }) {
                    playlist.append(PlaylistItem(path: url.path))
                }
            }
            if prevCount == 0 && !playlist.isEmpty {
                currentIndex = 0
            }
            saveState()
            rebuildMenu()
            if !isPlaying || player == nil {
                loadVideo(at: currentIndex)
            }
        }
    }

    @objc private func selectPlaylistItem(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, i < playlist.count else { return }
        currentIndex = i
        saveState()
        loadVideo(at: currentIndex)
        rebuildMenu()
        resetSwitchTimer()
    }

    @objc private func removeCurrent() {
        guard !playlist.isEmpty else { return }
        playlist.remove(at: currentIndex)
        if playlist.isEmpty {
            currentIndex = 0
            player?.replaceCurrentItem(with: nil)
            looper = nil
            isPlaying = false
            hideWebView()
            playerView.isHidden = false
        } else {
            if currentIndex >= playlist.count { currentIndex = playlist.count - 1 }
            loadVideo(at: currentIndex)
        }
        saveState()
        rebuildMenu()
        resetSwitchTimer()
    }

    @objc private func clearPlaylist() {
        playlist.removeAll()
        currentIndex = 0
        player?.replaceCurrentItem(with: nil)
        looper = nil
        isPlaying = false
        hideWebView()
        playerView.isHidden = false
        saveState()
        rebuildMenu()
        switchTimer?.invalidate()
        switchTimer = nil
    }

    // MARK: - Interval & shuffle

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let interval = SwitchInterval(rawValue: raw) else { return }
        switchInterval = interval
        saveInterval()
        rebuildMenu()
        resetSwitchTimer()
    }

    @objc private func toggleShuffle() {
        shuffle.toggle()
        saveShuffle()
        if shuffle {
            generateShuffleOrder()
        }
        rebuildMenu()
    }

    private func generateShuffleOrder() {
        guard playlist.count > 1 else { return }
        shuffledOrder = Array(0..<playlist.count).shuffled()
        // Make sure first item isn't current (unless only one)
        if shuffledOrder.first == currentIndex, shuffledOrder.count > 1 {
            shuffledOrder.swapAt(0, 1)
        }
        shuffleIndex = 0
    }

    // MARK: - Timer

    private func resetSwitchTimer() {
        switchTimer?.invalidate()
        switchTimer = nil
        guard switchInterval != .off, playlist.count > 1 else { return }
        switchTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(switchInterval.rawValue), repeats: true) { [weak self] _ in
            self?.nextTrack()
        }
    }

    @objc private func nextTrack() {
        guard playlist.count > 1 else { return }
        if shuffle {
            // Playlist edits invalidate the order; indices must stay in bounds
            if shuffledOrder.count != playlist.count { generateShuffleOrder() }
            currentIndex = shuffledOrder[shuffleIndex % shuffledOrder.count]
            shuffleIndex += 1
        } else {
            currentIndex = (currentIndex + 1) % playlist.count
        }
        saveState()
        loadVideo(at: currentIndex)
        rebuildMenu()
    }

    // MARK: - Video loading

    private func loadVideo(at index: Int) {
        guard index < playlist.count else { return }
        let item = playlist[index]
        let url = URL(fileURLWithPath: item.path)

        toggleMenuItem?.isEnabled = false

        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            showHTML(url: url)
        } else if ext == "webm" {
            beginTranscoding(sourceURL: url)
        } else {
            playVideo(url: url)
        }
    }

    // MARK: - HTML wallpaper

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let wv = WallpaperWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.isHidden = true
        window.contentView?.addSubview(wv)
        webView = wv
        return wv
    }

    private func showHTML(url: URL) {
        let wv = ensureWebView()
        // Grant read access to the folder so relative CSS/JS/image paths work
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        wv.isHidden = false
        playerView.isHidden = true

        // Release the video pipeline while HTML is showing
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        looper = nil
        isPlaying = true
        showingHTML = true
        hideTerminalSurface()
        updateInteractionState()

        toggleMenuItem?.isEnabled = false
        toggleMenuItem?.title = "⏸ 일시정지"
        nowPlayingItem?.title = nowPlayingText()
    }

    private func hideWebView() {
        guard let webView else { return }
        webView.isHidden = true
        webView.loadHTMLString("", baseURL: nil) // stop JS/animation CPU usage
        showingHTML = false
        updateInteractionState()
    }

    // Hide the terminal because a video/HTML surface is taking over. Turns the
    // persisted mode off too, since the user is explicitly choosing a wallpaper.
    private func hideTerminalSurface() {
        guard showingTerminal || terminalModeEnabled else { return }
        terminalView?.isHidden = true
        showingTerminal = false
        if terminalModeEnabled {
            terminalModeEnabled = false
            UserDefaults.standard.set(false, forKey: terminalModeKey)
        }
    }

    // Only intercept mouse/keyboard while an interactive wallpaper (HTML with
    // interaction on, or the terminal) is up; otherwise clicks must pass through
    // to the Finder desktop.
    // Finder's desktop-icon window sits above the desktop level and grabs all
    // clicks (rubber-band selection), so interactive mode must also raise the
    // window just above it — desktop icons are covered while this is on.
    private func updateInteractionState() {
        let interactive = showingTerminal || (showingHTML && htmlInteraction)
        window.ignoresMouseEvents = !interactive
        window.interactive = interactive
        let level = interactive
            ? Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            : Int(CGWindowLevelForKey(.desktopWindow))
        window.level = NSWindow.Level(rawValue: level)

        if showingTerminal, let tv = terminalView {
            // Route keyboard to the shell: activate the accessory app, make the
            // desktop window key, and focus the terminal view
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(tv)
        }
    }

    @objc private func toggleHTMLInteraction() {
        htmlInteraction.toggle()
        UserDefaults.standard.set(htmlInteraction, forKey: htmlInteractionKey)
        updateInteractionState()
        rebuildMenu()
    }

    // MARK: - Terminal wallpaper

    @objc private func toggleTerminal() {
        setTerminalMode(!terminalModeEnabled)
    }

    private func setTerminalMode(_ on: Bool) {
        terminalModeEnabled = on
        UserDefaults.standard.set(on, forKey: terminalModeKey)
        if on {
            showTerminal()
        } else {
            hideTerminalAndRestore()
        }
        rebuildMenu()
    }

    private func ensureTerminalView() -> WallpaperTerminalView {
        if let terminalView { return terminalView }
        let tv = WallpaperTerminalView(frame: window.contentView?.bounds ?? .zero)
        tv.autoresizingMask = [.width, .height]
        tv.isHidden = true
        tv.processDelegate = self
        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        tv.nativeBackgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        window.contentView?.addSubview(tv)
        terminalView = tv
        return tv
    }

    private func startShell(_ tv: WallpaperTerminalView) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Login shell so ~/.zprofile etc. are sourced; start in the home dir
        tv.startProcess(executable: shell, args: ["-l"], currentDirectory: home)
        shellRunning = true
    }

    private func showTerminal() {
        let tv = ensureTerminalView()

        // Take over the screen from any video/HTML surface
        player?.pause()
        isPlaying = false
        hideWebView()
        playerView.isHidden = true
        switchTimer?.invalidate()
        switchTimer = nil

        if !shellRunning {
            startShell(tv)
        }
        tv.isHidden = false
        showingTerminal = true
        updateInteractionState()

        toggleMenuItem?.isEnabled = false
        nowPlayingItem?.title = nowPlayingText()
    }

    private func hideTerminalAndRestore() {
        terminalView?.isHidden = true
        showingTerminal = false
        updateInteractionState()

        // Return to the playlist wallpaper
        if playlist.isEmpty {
            playerView.isHidden = false
        } else {
            loadVideo(at: currentIndex)
            resetSwitchTimer()
        }
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        saveMute()
        player?.isMuted = isMuted
        rebuildMenu()
    }

    private func playVideo(url: URL) {
        let asset = AVAsset(url: url)
        let playableKey = "playable"
        asset.loadValuesAsynchronously(forKeys: [playableKey]) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                var error: NSError?
                let status = asset.statusOfValue(forKey: playableKey, error: &error)
                if status == .loaded {
                    self.hideTerminalSurface()
                    self.hideWebView()
                    self.playerView.isHidden = false
                    let item = AVPlayerItem(asset: asset)
                    let avPlayer = AVQueuePlayer()
                    avPlayer.isMuted = self.isMuted
                    self.looper = AVPlayerLooper(player: avPlayer, templateItem: item)
                    self.player = avPlayer
                    self.playerView.playerLayer.player = avPlayer
                    self.playerView.playerLayer.videoGravity = .resizeAspectFill
                    avPlayer.play()
                    self.isPlaying = true
                    self.toggleMenuItem?.isEnabled = true
                    self.toggleMenuItem?.title = "⏸ 일시정지"
                    self.nowPlayingItem?.title = self.nowPlayingText()
                } else {
                    self.toggleMenuItem?.isEnabled = true
                    self.showLoadError(url: url, error: error)
                }
            }
        }
    }

    private func showLoadError(url: URL, error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "비디오 로드 실패"
        alert.informativeText = "\(url.lastPathComponent)를 불러올 수 없습니다.\n\(error?.localizedDescription ?? "알 수 없는 오류")"
        alert.runModal()
    }

    // MARK: - webm handling

    private func beginTranscoding(sourceURL: URL) {
        toggleMenuItem?.isEnabled = false
        toggleMenuItem?.title = "webm 변환 중..."
        nowPlayingItem?.title = "🔄 \(sourceURL.lastPathComponent) 변환중..."

        transcodeWebM(at: sourceURL) { [weak self] result in
            guard let self else { return }
            self.toggleMenuItem?.isEnabled = true
            switch result {
            case .success(let mp4URL):
                self.playVideo(url: mp4URL)
            case .failure(let error):
                self.toggleMenuItem?.title = self.isPlaying ? "⏸ 일시정지" : "▶ 재생"
                self.showTranscodeError(error)
                self.nowPlayingItem?.title = "❌ 변환 실패"
            }
        }
    }

    private func showTranscodeError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "webm 변환 실패"
        switch error {
        case TranscodeError.ffmpegNotFound:
            alert.informativeText = "ffmpeg를 찾을 수 없습니다. 터미널에서 'brew install ffmpeg'로 설치한 뒤 다시 시도해주세요."
        default:
            alert.informativeText = "동영상을 변환하는 중 오류가 발생했습니다: \(error.localizedDescription)"
        }
        alert.runModal()
    }

    private func locateFFmpeg() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func cachedMP4URL(for sourceURL: URL) -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperVideo/Transcoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(sourceURL.path)|\(mtime)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        return cacheDir.appendingPathComponent("\(hash).mp4")
    }

    private func transcodeWebM(at sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let destURL = cachedMP4URL(for: sourceURL)
        if FileManager.default.fileExists(atPath: destURL.path) {
            completion(.success(destURL))
            return
        }

        guard let ffmpegPath = locateFFmpeg() else {
            completion(.failure(TranscodeError.ffmpegNotFound))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-y",
                "-i", sourceURL.path,
                "-an",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "20",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                destURL.path
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: destURL.path) {
                    DispatchQueue.main.async { completion(.success(destURL)) }
                } else {
                    try? FileManager.default.removeItem(at: destURL)
                    DispatchQueue.main.async { completion(.failure(TranscodeError.ffmpegFailed)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Playback controls

    @objc private func togglePlayback() {
        guard !showingHTML, let player = player else { return }
        if isPlaying {
            player.pause()
            toggleMenuItem?.title = "▶ 재생"
        } else {
            player.play()
            toggleMenuItem?.title = "⏸ 일시정지"
        }
        isPlaying.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            rebuildMenu()
        } catch {
            NSLog("Failed to toggle launch-at-login: \(error)")
        }
    }
}

// MARK: - Terminal process delegate

extension AppDelegate: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shellRunning = false
            // `exit` at the prompt closes the terminal wallpaper; re-enabling
            // it from the menu starts a fresh shell
            guard self.showingTerminal else { return }
            self.setTerminalMode(false)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
