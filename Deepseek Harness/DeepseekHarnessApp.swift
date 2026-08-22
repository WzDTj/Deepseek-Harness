import Combine
import SwiftUI
import WebKit

/// The main window: an embedded `WKWebView` pointed at the local `dsh web`
/// address (http://127.0.0.1:<port>). The harness auto-starts when the window
/// appears and auto-stops when the app terminates; no toolbar/address bar is
/// shown.
struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        WebView(url: model.webURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                model.activate()
            }
            .alert("dsh 启动失败", isPresented: $model.showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(model.errorMessage)
            }
    }
}

// MARK: - Web view

struct WebView: NSViewRepresentable {
    var url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = nil
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let url, nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }
}

// MARK: - App entry

@main
struct DeepseekHarnessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the harness before the app exits.
        DshProcessManager.shared.stop()
    }
}

// MARK: - Controller

@MainActor
final class AppModel: ObservableObject {
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var webURL: URL?

    private let processManager = DshProcessManager.shared
    private let settings = AppSettings.shared
    private var didActivate = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        processManager.onLog = { line in
            print("[dsh]", line)
        }
        processManager.stateDidChange = { [weak self] in
            Task { @MainActor in
                self?.render(state: self?.processManager.state ?? .idle)
            }
        }
        // Seed the manager with the effective settings config and then keep it
        // in sync when the user edits the Settings window.
        processManager.reconfigure(buildConfig())

        Publishers.MergeMany(
            settings.$launchMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$port.map { _ in () }.eraseToAnyPublisher(),
            settings.$autoPort.map { _ in () }.eraseToAnyPublisher(),
            settings.$dshPath.map { _ in () }.eraseToAnyPublisher(),
            settings.$nodePath.map { _ in () }.eraseToAnyPublisher(),
            settings.$sourcePath.map { _ in () }.eraseToAnyPublisher(),
            settings.$pnpmPath.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.applySettings()
        }
        .store(in: &cancellables)
    }

    /// Called when the window appears: ensure the harness is running once.
    func activate() {
        guard !didActivate else { return }
        didActivate = true
        processManager.startIfNeeded()
    }

    /// Build a harness `Config` from the current settings; already applied /
    /// default values produce the same config so reconfiguration is skipped.
    private var lastAppliedConfig: DshProcessManager.Config?

    /// Translate the current `AppSettings` into a harness `Config`.
    private func buildConfig() -> DshProcessManager.Config {
        var cfg = DshProcessManager.Config()
        cfg.launchMode = settings.resolvedLaunchMode
        cfg.autoPort = settings.resolvedAutoPort
        cfg.port = settings.resolvedPort
        cfg.dshPathOverride = settings.resolvedDshPath
        cfg.nodePathOverride = settings.resolvedNodePath
        cfg.sourcePathOverride = settings.resolvedSourcePath
        cfg.pnpmPathOverride = settings.resolvedPnpmPath
        return cfg
    }

    /// Push the current settings into the running harness (restarting it if
    /// needed) and make sure it's up once the app is active.
    private func applySettings() {
        let cfg = buildConfig()
        // Skip the no-op initial/config-equivalent emissions.
        if cfg == lastAppliedConfig { return }
        lastAppliedConfig = cfg
        processManager.reconfigure(cfg)
        if didActivate {
            processManager.startIfNeeded()
        }
    }

    private func render(state: DshProcessManager.State) {
        switch state {
        case .idle, .starting, .restarting:
            break
        case .ready(let url):
            webURL = url
        case .failed(let reason):
            if !reason.isEmpty { showFailure(reason) }
        }
    }

    private func showFailure(_ message: String) {
        errorMessage = message
        showError = true
    }
}
