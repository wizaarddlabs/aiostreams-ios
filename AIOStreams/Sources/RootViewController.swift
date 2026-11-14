import AetherEngineFeatures
import SafariServices
import UIKit
import WebKit

/// The video beneath, the subtitles over it, and the page on top drawing every screen and the player's controls.
@MainActor
final class RootViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    private let engine: AetherEngine
    private let videoView = AetherPlayerView()
    private let overlay = SubtitleOverlayView()
    /// The video and subtitles, full screen or as the page's mini player.
    private lazy var stage = VideoStage(video: videoView, subtitles: overlay)
    /// Where a drag of the small video started.
    private var dragFrom: CGPoint?
    private let thumbnails = ThumbnailStore()
    private let bridge = Bridge()
    private var webView: WKWebView!
    private var player: PlayerChannel!
    private var pictureInPicture: PictureInPicture!
    /// The web app's logo, covering the page until its own splash has drawn.
    private var launchLogo: LaunchLogo?

    private var fullscreen = false
    private var linksReady = false
    private var pendingLinks: [String] = []

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine could not start: \(error)")
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black

        engine.bind(view: videoView)
        overlay.isHidden = true
        stage.view.frame = root.bounds
        stage.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(stage.view)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(WebAssets(thumbnails: thumbnails), forURLScheme: WebAssets.scheme)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "AIOStreams-iOS/\(AppInfo.version)"
        configuration.websiteDataStore = .default()
        bridge.install(into: configuration.userContentController)
        configuration.userContentController.addUserScript(
            WKUserScript(source: LaunchLogo.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        if let seed = DemoMode.storageScript {
            configuration.userContentController.addUserScript(
                WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        bridge.webView = webView

        for view in [webView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        let cover = LaunchLogo(frame: root.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(cover)
        launchLogo = cover
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        player = PlayerChannel(engine: engine, overlay: overlay, thumbnails: thumbnails) { [weak self] message in
            self?.bridge.send(message)
        }
        stage.web = webView
        player.showVideo = { [weak self] shown in
            self?.stage.show(shown)
            self?.overlay.isHidden = !shown
        }
        // Drags of the small video, which the page can't follow over the app's own video.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragMiniPlayer(_:)))
        drag.delegate = self
        view.addGestureRecognizer(drag)
        pictureInPicture = PictureInPicture(engine: engine, channel: player) { [weak self] message in
            self?.bridge.send(message)
        }
        player.mediaChanged = { [weak self] in self?.pictureInPicture?.refresh() }
        // The window draws the subtitles itself while it's open.
        pictureInPicture.changed = { [weak self] active in
            guard let self else { return }
            self.overlay.isHidden = active || !self.player.hasMedia
        }
        pictureInPicture.restore = { [weak self] in self?.view.window?.makeKeyAndVisible() }
        pictureInPicture.failed = { [weak self] in
            guard let self, self.presentedViewController == nil,
                  UIApplication.shared.applicationState == .active else { return }
            let alert = UIAlertController(title: "Picture in Picture",
                                          message: "Picture in Picture isn't available for this video right now.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
        DownloadQueue.shared.send = { [weak self] message in self?.bridge.send(message) }
        bridge.onMessage = { [weak self] type, message in self?.handle(type, message) }
        webView.load(URLRequest(url: DemoMode.startURL ?? WebAssets.startURL))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A turn or resize moves the page's frame with it.
        stage.refresh()
    }

    // MARK: - The mini player's drag

    /// Only a drag that starts on the small video, where the page lets it be dragged.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer, gestureRecognizer.view === view else { return true }
        guard let rect = stage.draggableRect else { return false }
        return rect.contains(gestureRecognizer.location(in: webView))
    }

    /// The page reads where the video was let go and docks it in the nearest corner.
    @objc private func dragMiniPlayer(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            dragFrom = stage.draggableRect?.origin
            bridge.send(["type": "player-frame", "event": "grabbed"])
        case .changed, .ended, .cancelled:
            guard let start = dragFrom else { return }
            let moved = pan.translation(in: webView)
            let origin = CGPoint(x: start.x + moved.x, y: start.y + moved.y)
            stage.drag(to: origin)
            let done = pan.state != .changed
            bridge.send(["type": "player-frame", "event": done ? "moved" : "moving", "x": origin.x, "y": origin.y])
            if done { dragFrom = nil }
        default:
            break
        }
    }

    override var prefersStatusBarHidden: Bool { fullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { fullscreen }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { fullscreen ? .all : [] }

    // MARK: - Messages

    private func handle(_ type: String, _ message: [String: Any]) {
        if player.handle(type, message) { return }
        if DownloadQueue.shared.handle(type, message) { return }
        switch type {
        case "app-info":
            bridge.send([
                "type": "app-info",
                "app": AppInfo.version,
                "platform": "ios",
                "mpv": NSNull(),
                "ffmpeg": NSNull(),
                "player": AppInfo.player,
            ])
        case "player-frame":
            // The mini player: where the page wants the video, or nil for full screen.
            stage.place(VideoFrame.from(message))
        case "splash-shown":
            // The page shows the same logo now.
            launchLogo?.lift()
            launchLogo = nil
        case "pip":
            // The page's Picture in Picture button; `value: false` asks to leave it.
            if JSON.flag(message["value"]) == false { pictureInPicture.stopForRestore() }
            else { pictureInPicture.toggle() }
        case "fullscreen":
            setFullscreen(JSON.flag(message["value"]) ?? !fullscreen)
        case "update-check":
            // Updates come from wherever the IPA was installed from.
            bridge.send(["type": "update-state", "state": "off", "channel": NSNull(), "version": NSNull(), "error": NSNull()])
        case "external-players":
            bridge.send(["type": "external-players", "players": [Any]()])
        case "video-output":
            bridge.send(["type": "video-output", "outputs": [Any](), "running": "system", "chosen": "system"])
        case "audio-devices":
            bridge.send(["type": "audio-devices", "devices": NSNull()])
        case "youtube-resolve":
            // A trailer: the page plays the stream the app finds, as the Android and desktop apps do.
            let request = message["request"] ?? ""
            YouTube.resolve(message["id"] as? String ?? "") { [weak self] stream in
                var answer: [String: Any] = ["type": "youtube-resolved", "request": request, "url": stream?.url ?? NSNull()]
                if let language = stream?.originalLanguage { answer["originalLanguage"] = language }
                self?.bridge.send(answer)
            }
        case "licenses":
            bridge.send(AppInfo.licenses)
        case "diagnostics":
            let text = [
                "App: AIOStreams iOS \(AppInfo.version)",
                "Device: \(AppInfo.deviceModel), iOS \(UIDevice.current.systemVersion)",
                "Web: \(message["web"] as? String ?? "?")",
                "Server: \(message["server"] as? String ?? "none")",
                player.diagnostics,
                "",
                AppLog.recent,
            ].joined(separator: "\n")
            bridge.send(["type": "diagnostics", "text": text])
        case "crash-report":
            bridge.send(["type": "crash-report"])
        case "links-ready":
            linksReady = true
            for link in pendingLinks { bridge.send(["type": "link", "url": link]) }
            pendingLinks.removeAll()
        case "save-file":
            saveFile(name: message["name"] as? String ?? "file.txt", text: message["text"] as? String ?? "")
        case "restart":
            webView.reload()
        case "log":
            let level = message["level"] as? String
            let text = message["message"] as? String ?? ""
            level == "warn" ? AppLog.warn("web", text) : AppLog.info("web", text)
        case "web-error":
            AppLog.warn("web", message["message"] as? String ?? "")
        case "exit", "open-logs", "player-key", "window-buttons", "discord-check", "external-choose",
             "external-open", "external-close", "watch-next", "keyboard-completions", "player-engine",
             "player-retry", "crash-seen", "set-level", "levels", "voice-search", "voice-cancel":
            break
        default:
            AppLog.info("bridge", "unhandled \(type)")
        }
    }

    func openLink(_ url: URL) {
        guard url.scheme == WebAssets.scheme else { return }
        if linksReady, bridge.connected {
            bridge.send(["type": "link", "url": url.absoluteString])
        } else {
            pendingLinks.append(url.absoluteString)
        }
    }

    /// The app has the whole screen, rather than a part of it in Split View or Slide Over.
    private var ownsScreen: Bool {
        guard let window = view.window, let screen = window.windowScene?.screen else { return true }
        let size = window.bounds.size, full = screen.bounds.size
        return abs(size.width - full.width) < 1 && abs(size.height - full.height) < 1
            || abs(size.width - full.height) < 1 && abs(size.height - full.width) < 1
    }

    private func setFullscreen(_ on: Bool) {
        fullscreen = on
        // Landscape for the player only with the whole screen; beside another app, the window stays as it is.
        let turns = on && ownsScreen
        AppDelegate.orientations = turns ? .landscape : .allButUpsideDown
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene, turns || !on {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: turns ? .landscape : .allButUpsideDown)) { error in
                AppLog.info("app", "orientation: \(error.localizedDescription)")
            }
        }
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        bridge.send(["type": "fullscreen", "value": on])
    }

    private func saveFile(name: String, text: String) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(share, animated: true)
    }

    private func openExternally(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            present(SFSafariViewController(url: url), animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let ours = url.scheme == WebAssets.scheme && url.host == "localhost"
        // Frames the page embeds (trailers, sign-in pages) load in place; anything else leaves the app.
        if ours || url.scheme == "about" || navigationAction.targetFrame?.isMainFrame == false {
            return decisionHandler(.allow)
        }
        openExternally(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        bridge.pageLoading()
        linksReady = false
        player?.pageLoading()
        if fullscreen { setFullscreen(false) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.warn("app", "the page's process ended; loading it again")
        player?.pageLoading()
        webView.reload()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}
