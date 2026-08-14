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

    var body: some Scene {
        WindowGroup {
            ContentView()
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
    private var didActivate = false

    init() {
        processManager.onLog = { line in
            print("[dsh]", line)
        }
        processManager.stateDidChange = { [weak self] in
            Task { @MainActor in
                self?.render(state: self?.processManager.state ?? .idle)
            }
        }
    }

    /// Called when the window appears: ensure the harness is running once.
    func activate() {
        guard !didActivate else { return }
        didActivate = true
        processManager.startIfNeeded()
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
