import SwiftUI
import WebKit
import AVFoundation
import UIKit

struct WebPlayerContainerView: View {
    let game: Game
    let entryHTMLURL: URL
    let readAccessURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var orientationManager: OrientationManager

    @State private var reloadTrigger = UUID()
    @State private var layoutFixTrigger = UUID()
    @State private var showExitConfirmation = false
    @State private var isFullScreenStretch = false
    @State private var isFloatingBarHidden = false
    @State private var showDebugConsole = false
    @State private var consoleLogs: [ConsoleLogEntry] = []
    @State private var pendingJSCommand: String?

    private var errorCount: Int {
        consoleLogs.filter { $0.level == .error }.count
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            WebPlayerView(
                entryHTMLURL: entryHTMLURL,
                readAccessURL: readAccessURL,
                reloadTrigger: reloadTrigger,
                layoutFixTrigger: layoutFixTrigger,
                isFullScreenStretch: isFullScreenStretch,
                pendingJSCommand: $pendingJSCommand,
                onConsoleLog: { entry in
                    consoleLogs.append(entry)
                    if consoleLogs.count > 400 {
                        consoleLogs.removeFirst(consoleLogs.count - 400)
                    }
                }
            )
            .ignoresSafeArea()

            floatingToolbar

            if showDebugConsole {
                VStack {
                    Spacer()
                    WebDebugConsoleDrawer(
                        logs: $consoleLogs,
                        onExecuteJS: { cmd in pendingJSCommand = cmd },
                        onClose: { showDebugConsole = false }
                    )
                    .frame(maxHeight: 260)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            orientationManager.apply(orientationManager.currentMode)
        }
        .onDisappear {
            orientationManager.resetToDefault()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                orientationManager.apply(orientationManager.currentMode)
                layoutFixTrigger = UUID()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            orientationManager.apply(orientationManager.currentMode)
            layoutFixTrigger = UUID()
        }
        .confirmationDialog("确定返回游戏库吗？", isPresented: $showExitConfirmation, titleVisibility: .visible) {
            Button("返回游戏库", role: .destructive) { dismiss() }
            Button("继续游戏", role: .cancel) {}
        } message: {
            Text("退出前请确认已在游戏内完成存档。")
        }
    }

    @ViewBuilder
    private var floatingToolbar: some View {
        if isFloatingBarHidden {
            Button {
                isFloatingBarHidden = false
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(10)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    showExitConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.caption.weight(.bold))
                        Text("游戏库")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
                }

                Button {
                    isFullScreenStretch.toggle()
                    layoutFixTrigger = UUID()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFullScreenStretch ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                        Text(isFullScreenStretch ? "原始比例" : "全屏")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isFullScreenStretch ? Color.indigo.opacity(0.85) : Color.white.opacity(0.18), in: Capsule())
                }

                Menu {
                    Section("屏幕方向 (\(orientationManager.currentMode.rawValue))") {
                        ForEach(ScreenOrientationMode.allCases) { mode in
                            Button {
                                orientationManager.apply(mode)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    layoutFixTrigger = UUID()
                                }
                            } label: {
                                Label(
                                    mode.rawValue,
                                    systemImage: orientationManager.currentMode == mode ? "checkmark.circle.fill" : mode.iconName
                                )
                            }
                        }
                    }

                    Section("画面与调试") {
                        Button {
                            layoutFixTrigger = UUID()
                        } label: {
                            Label("修复画面缩放 / 唤醒音频", systemImage: "aspectratio")
                        }
                        Button {
                            showDebugConsole.toggle()
                        } label: {
                            Label(
                                errorCount > 0 ? "调试控制台 (\(errorCount) 个错误)" : "调试控制台 (\(consoleLogs.count))",
                                systemImage: "terminal"
                            )
                        }
                    }

                    Section("游戏控制") {
                        Button {
                            reloadTrigger = UUID()
                        } label: {
                            Label("重新加载游戏", systemImage: "arrow.clockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                Button {
                    isFloatingBarHidden = true
                } label: {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
    }
}

struct WebPlayerView: UIViewRepresentable {
    let entryHTMLURL: URL
    let readAccessURL: URL
    let reloadTrigger: UUID
    let layoutFixTrigger: UUID
    let isFullScreenStretch: Bool
    @Binding var pendingJSCommand: String?
    let onConsoleLog: (ConsoleLogEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onConsoleLog: onConsoleLog)
    }

    func makeUIView(context: Context) -> WKWebView {
        Self.configureAudioSession()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: Coordinator.consoleHandlerName)

        let preloadCompatJS = """
        (function() {
            function sendLog(level, args) {
                try {
                    var msg = Array.prototype.slice.call(args).map(function(item) {
                        if (item instanceof Error) {
                            return item.name + ': ' + item.message;
                        }
                        if (typeof item === 'object' && item !== null) {
                            try { return JSON.stringify(item); } catch (e) { return String(item); }
                        }
                        return String(item);
                    }).join(' ');
                    window.webkit.messageHandlers.tyranoConsole.postMessage({ level: level, message: msg });
                } catch (e) {}
            }

            var origLog = console.log, origInfo = console.info, origWarn = console.warn, origError = console.error;
            console.log = function() { sendLog('LOG', arguments); origLog.apply(console, arguments); };
            console.info = function() { sendLog('LOG', arguments); origInfo.apply(console, arguments); };
            console.warn = function() { sendLog('WARN', arguments); origWarn.apply(console, arguments); };
            console.error = function() { sendLog('ERROR', arguments); origError.apply(console, arguments); };

            window.addEventListener('error', function(e) {
                var detail = (e.message || 'Error') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '');
                sendLog('ERROR', [detail]);
            }, true);

            if (typeof window.process === 'undefined') {
                window.process = {
                    platform: 'darwin',
                    versions: { node: '18.0.0', electron: '25.0.0' },
                    env: {},
                    cwd: function() { return '.'; }
                };
            }
            if (typeof window.nw === 'undefined') {
                window.nw = {
                    App: { argv: [], quit: function() {} },
                    Window: { get: function() { return { enterFullscreen: function(){}, leaveFullscreen: function(){}, toggleFullscreen: function(){}, resizeTo: function(){}, close: function(){} }; } }
                };
            }
            window.close = function() {};

            var origCreateElement = document.createElement.bind(document);
            document.createElement = function(tagName) {
                var el = origCreateElement(tagName);
                if (typeof tagName === 'string') {
                    var lower = tagName.toLowerCase();
                    if (lower === 'video') {
                        el.setAttribute('playsinline', '');
                        el.setAttribute('webkit-playsinline', '');
                        el.playsInline = true;
                        el.preload = 'auto';
                    } else if (lower === 'audio') {
                        el.preload = 'auto';
                        el.addEventListener('error', function() {
                            var src = el.getAttribute('src') || el.src || '';
                            if (/\.ogg(\?.*)?$/i.test(src) && !el.dataset.fallbackTried) {
                                el.dataset.fallbackTried = 'm4a';
                                el.src = src.replace(/\.ogg(\?.*)?$/i, '.m4a$1');
                                el.load();
                                el.play().catch(function(){});
                            } else if (el.dataset.fallbackTried === 'm4a') {
                                el.dataset.fallbackTried = 'mp3';
                                el.src = src.replace(/\.m4a(\?.*)?$/i, '.mp3$1');
                                el.load();
                                el.play().catch(function(){});
                            }
                        }, true);
                    }
                }
                return el;
            };
        })();
        """

        let postloadViewportJS = """
        (function() {
            var style = document.createElement('style');
            style.innerHTML = `
                * {
                    -webkit-touch-callout: none !important;
                    -webkit-user-select: none !important;
                    user-select: none !important;
                    -webkit-tap-highlight-color: transparent !important;
                }
                html, body {
                    margin: 0 !important;
                    padding: 0 !important;
                    width: 100% !important;
                    height: 100% !important;
                    overflow: hidden !important;
                    position: fixed !important;
                    inset: 0 !important;
                    background-color: #000000 !important;
                    touch-action: manipulation;
                }
                video { object-fit: contain; }
            `;
            document.head.appendChild(style);

            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
                meta = document.createElement('meta');
                meta.name = 'viewport';
                document.head.appendChild(meta);
            }
            meta.content = 'width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover';

            window.__tyranoStretchMode = false;

            window.__tyranoApplyStretch = function() {
                var target = document.getElementById('tyrano_base') || document.querySelector('.tyrano_base');
                if (!target) return;
                if (window.__tyranoStretchMode) {
                    var scWidth = parseFloat(target.style.width) || target.clientWidth || 1280;
                    var scHeight = parseFloat(target.style.height) || target.clientHeight || 720;
                    var scaleX = window.innerWidth / scWidth;
                    var scaleY = window.innerHeight / scHeight;
                    target.style.transformOrigin = '0 0';
                    target.style.transform = 'scale(' + scaleX + ', ' + scaleY + ')';
                    target.style.left = '0px';
                    target.style.top = '0px';
                    target.style.margin = '0px';
                } else {
                    target.style.left = '';
                    target.style.top = '';
                }
            };

            window.__tyranoSetFullScreen = function(stretch) {
                window.__tyranoStretchMode = !!stretch;
                window.__tyranoFixViewport();
            };

            window.__tyranoFixViewport = function() {
                window.scrollTo(0, 0);
                try {
                    if (window.Howler && window.Howler.ctx && window.Howler.ctx.state !== 'running') {
                        window.Howler.ctx.resume();
                    }
                } catch (e) {}

                [0, 120, 350].forEach(function(delay) {
                    setTimeout(function() {
                        window.scrollTo(0, 0);
                        window.dispatchEvent(new Event('resize'));
                        window.dispatchEvent(new Event('orientationchange'));
                        if (window.jQuery) { window.jQuery(window).trigger('resize'); }
                        try {
                            if (window.TYRANO && window.TYRANO.kag && window.TYRANO.kag.view && typeof window.TYRANO.kag.view.resizeScreen === 'function') {
                                window.TYRANO.kag.view.resizeScreen();
                            }
                        } catch (e) {}
                        window.__tyranoApplyStretch();
                    }, delay);
                });
            };
        })();
        """

        contentController.addUserScript(WKUserScript(source: preloadCompatJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        contentController.addUserScript(WKUserScript(source: postloadViewportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        context.coordinator.lastReloadTrigger = reloadTrigger
        context.coordinator.lastLayoutFixTrigger = layoutFixTrigger
        context.coordinator.lastStretchState = isFullScreenStretch
        webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            Self.configureAudioSession()
            webView.loadFileURL(entryHTMLURL, allowingReadAccessTo: readAccessURL)
        }

        if context.coordinator.lastStretchState != isFullScreenStretch {
            context.coordinator.lastStretchState = isFullScreenStretch
            let flag = isFullScreenStretch ? "true" : "false"
            webView.evaluateJavaScript("if (typeof window.__tyranoSetFullScreen === 'function') { window.__tyranoSetFullScreen(\(flag)); }", completionHandler: nil)
        }

        if context.coordinator.lastLayoutFixTrigger != layoutFixTrigger {
            context.coordinator.lastLayoutFixTrigger = layoutFixTrigger
            Self.configureAudioSession()
            Self.repairWebViewViewport(webView, stretch: isFullScreenStretch)
        }

        if let jsCommand = pendingJSCommand {
            DispatchQueue.main.async {
                self.pendingJSCommand = nil
            }
            context.coordinator.log(level: .log, message: "> \(jsCommand)")
            webView.evaluateJavaScript(jsCommand) { result, error in
                if let error {
                    context.coordinator.log(level: .error, message: error.localizedDescription)
                } else if let result {
                    context.coordinator.log(level: .log, message: "<- \(String(describing: result))")
                }
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.consoleHandlerName)
    }

    static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {}
    }

    static func repairWebViewViewport(_ webView: WKWebView, stretch: Bool) {
        webView.scrollView.setZoomScale(1.0, animated: false)
        webView.scrollView.setContentOffset(.zero, animated: false)
        webView.scrollView.contentInset = .zero
        webView.setNeedsLayout()
        webView.layoutIfNeeded()

        let flag = stretch ? "true" : "false"
        webView.evaluateJavaScript("""
        if (typeof window.__tyranoSetFullScreen === 'function') {
            window.__tyranoSetFullScreen(\(flag));
        } else if (typeof window.__tyranoFixViewport === 'function') {
            window.__tyranoFixViewport();
        }
        """, completionHandler: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let consoleHandlerName = "tyranoConsole"

        weak var webView: WKWebView?
        var lastReloadTrigger: UUID?
        var lastLayoutFixTrigger: UUID?
        var lastStretchState: Bool = false
        let onConsoleLog: (ConsoleLogEntry) -> Void

        init(onConsoleLog: @escaping (ConsoleLogEntry) -> Void) {
            self.onConsoleLog = onConsoleLog
            super.init()
        }

        func log(level: ConsoleLogLevel, message: String) {
            onConsoleLog(ConsoleLogEntry(timestamp: Date(), level: level, message: message))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.consoleHandlerName,
                  let body = message.body as? [String: Any],
                  let levelStr = body["level"] as? String,
                  let text = body["message"] as? String else {
                return
            }
            let level = ConsoleLogLevel(rawValue: levelStr) ?? .log
            log(level: level, message: text)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log(level: .log, message: "[WebKit] 已加载: \(webView.url?.lastPathComponent ?? "index.html")")
            WebPlayerView.repairWebViewViewport(webView, stretch: lastStretchState)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor () -> Void
        ) {
            guard let presenter = Self.topViewController() else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            guard let presenter = Self.topViewController() else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }

        private static func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                return nil
            }
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }
}

struct WebDebugConsoleDrawer: View {
    @Binding var logs: [ConsoleLogEntry]
    let onExecuteJS: (String) -> Void
    let onClose: () -> Void

    @State private var selectedLevel: ConsoleLogLevel = .all
    @State private var jsInput: String = ""

    private var filteredLogs: [ConsoleLogEntry] {
        selectedLevel == .all ? logs : logs.filter { $0.level == selectedLevel }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Web 控制台")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)

                Picker("级别", selection: $selectedLevel) {
                    ForEach(ConsoleLogLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                Button {
                    logs.removeAll()
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.92))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredLogs) { entry in
                        Text("[\(entry.level.rawValue)] \(entry.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(entry.level == .error ? .red : (entry.level == .warn ? .yellow : .white))
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(white: 0.08).opacity(0.92))

            HStack(spacing: 8) {
                TextField("输入 JS 表达式", text: $jsInput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("执行") {
                    let cmd = jsInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cmd.isEmpty else { return }
                    onExecuteJS(cmd)
                    jsInput = ""
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.95))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }
}
