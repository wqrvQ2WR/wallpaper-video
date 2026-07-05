import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Desktop-level window that hosts the video

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

enum TranscodeError: Error {
    case ffmpegNotFound
    case ffmpegFailed
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: DesktopWindow!
    private var playerView: PlayerView!
    private var queuePlayer: AVQueuePlayer!
    private var looper: AVPlayerLooper?
    private var isPlaying = false

    private let defaultsKey = "WallpaperVideoPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupDesktopWindow()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if let savedPath = UserDefaults.standard.string(forKey: defaultsKey) {
            handleSelectedVideo(url: URL(fileURLWithPath: savedPath))
        }
    }

    // MARK: Status bar menu

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

        let menu = NSMenu()
        menu.addItem(withTitle: "비디오 선택...", action: #selector(chooseVideo), keyEquivalent: "o").target = self
        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(title: "일시정지", action: #selector(togglePlayback), keyEquivalent: "p")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private var loginMenuItem: NSMenuItem? {
        statusItem.menu?.item(withTitle: "로그인 시 자동 실행")
    }

    private var toggleMenuItem: NSMenuItem? {
        statusItem.menu?.item(withTitle: "일시정지") ?? statusItem.menu?.item(withTitle: "재생")
    }

    // MARK: Desktop window

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
        window.hasShadow = false

        playerView = PlayerView(frame: screen.frame)
        playerView.autoresizingMask = [.width, .height]
        window.contentView = playerView

        window.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
    }

    // MARK: Actions

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "배경화면으로 사용할 비디오 선택"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var contentTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        if let webmType = UTType(filenameExtension: "webm") {
            contentTypes.append(webmType)
        }
        panel.allowedContentTypes = contentTypes

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: defaultsKey)
            handleSelectedVideo(url: url)
        }
    }

    // MARK: webm handling

    private func handleSelectedVideo(url: URL) {
        if url.pathExtension.lowercased() == "webm" {
            beginTranscoding(sourceURL: url)
        } else {
            loadVideo(url: url)
        }
    }

    private func beginTranscoding(sourceURL: URL) {
        toggleMenuItem?.isEnabled = false
        toggleMenuItem?.title = "webm 변환 중..."

        transcodeWebM(at: sourceURL) { [weak self] result in
            guard let self else { return }
            self.toggleMenuItem?.isEnabled = true
            switch result {
            case .success(let mp4URL):
                self.loadVideo(url: mp4URL)
            case .failure(let error):
                self.toggleMenuItem?.title = self.isPlaying ? "일시정지" : "재생"
                self.showTranscodeError(error)
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

    private func loadVideo(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        playerView.playerLayer.player = player
        playerView.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        isPlaying = true
        toggleMenuItem?.title = "일시정지"
    }

    @objc private func togglePlayback() {
        guard let player = queuePlayer else { return }
        if isPlaying {
            player.pause()
            toggleMenuItem?.title = "재생"
        } else {
            player.play()
            toggleMenuItem?.title = "일시정지"
        }
        isPlaying.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                loginMenuItem?.state = .off
            } else {
                try SMAppService.mainApp.register()
                loginMenuItem?.state = .on
            }
        } catch {
            NSLog("Failed to toggle launch-at-login: \(error)")
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
