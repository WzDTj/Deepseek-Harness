import Foundation
import Darwin

/// Manages the lifecycle of a child `dsh --profile web` process and exposes
/// the loopback URL once the web server is ready.
///
/// The app-shell relies on a **local**, non-self-contained `dsh` install:
/// the child process is launched through the user's shell PATH (which GUI apps
/// do not inherit, so we resolve it explicitly). `DSH_HOME` is not set here so
/// ordering stays as-documented: user config layers plus dsh's built-in `web`
/// profile template are used.
///
/// Port strategy: default to `DSH_PORT` env or 3080. Before spawning, the
/// configured port is probed — if an instance is already serving there (e.g.
/// started via npx/browser), it is reused instead of failing with EADDRINUSE.
/// When `autoPort` is true, `--port 0` is used and the real port is read back
/// from the process's printed `dsh web: http://127.0.0.1:<port>` line. Keep the
/// default host pinned to `127.0.0.1` (`--host 0.0.0.0` is rejected by dsh).
final class DshProcessManager {

    struct Config {
        var port: Int = DshProcessManager.defaultPort
        var host: String = "127.0.0.1"
        /// Extra arguments appended to the `dsh --profile web` invocation.
        var extraArgs: [String] = []
        /// Use `--port 0` and parse the real port back from stdout.
        var autoPort: Bool = false
    }

    enum State: Equatable {
        case idle
        case starting
        case ready(URL)
        case failed(String)
        /// Stopped, but a watchdog restart is already scheduled.
        case restarting(reason: String)
    }

    enum DshError: LocalizedError {
        case notFound(String)
        case launchFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notFound(let hint):
                return "找不到可用的 dsh 命令。\(hint)"
            case .launchFailed(let detail):
                return "无法启动 dsh web：\(detail)"
            case .timedOut:
                return "dsh web 在超时时间内未就绪。"
            }
        }
    }

    // MARK: - Public surface

    /// Shared manager used by the app UI and lifecycle hooks.
    static let shared = DshProcessManager()

    private(set) var state: State = .idle {
        didSet { stateDidChange?() }
    }

    /// Called on every state transition. Use it to drive the UI on the main queue.
    var stateDidChange: (() -> Void)?
    /// Called when the process prints a line (stdout or stderr).
    var onLog: ((String) -> Void)?

    private(set) var config: Config
    var port: Int { config.port }

    // MARK: - Internals

    private var process: Process?
    private var readinessTimer: Timer?
    private var stdoutBaseline = 0
    private var seenPort: Int?
    /// Tracks consecutive unattended auto-restarts so a wedged dsh (e.g.
    /// persistent port conflict) doesn't loop forever.
    private var restartCount = 0
    private let maxRestartAttempts = 3

    private static let defaultPort: Int = {
        (ProcessInfo.processInfo.environment["DSH_PORT"]).flatMap(Int.init) ?? 3080
    }()

    private var autoPort: Bool { config.autoPort }

    init(config: Config = Config()) {
        self.config = config
    }

    deinit {
        stopQuietly()
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() throws -> Bool {
        if case .ready = state {
            return false // already running / attached
        }

        // Prefer an already-running dsh web on the configured port: a local
        // harness may be started elsewhere (npx, browser, another client).
        // Reuse it instead of failing with EADDRINUSE.
        let candidateURL = URL(string: "http://\(config.host):\(config.port)")
        if !autoPort, let candidateURL, Self.isHealthy(url: candidateURL) {
            restartCount = 0
            transition(.ready(candidateURL))
            return false // attached to existing instance
        }

        let (runtime, url) = try prepareLaunch()
        transition(.starting)
        launch(executable: runtime.executableURL, arguments: runtime.arguments, path: runtime.path)

        if let url {
            // Without auto-port we don't need to parse stdout; poll health only.
            beginReadinessPoll(finalURL: url, healthPort: config.port)
        } else {
            // autoPort: wait for the printed URL line, then poll on that port.
            awaitPrintedPort()
        }
        return true
    }

    /// Non-throwing convenience wrapper.
    func startIfNeeded() {
        if case .ready = state { return }
        do { _ = try start() } catch {
            transition(.failed(error.localizedDescription))
        }
    }

    func stop() {
        stopQuietly()
        transition(.idle)
    }

    /// Kill the child and, if subscribed, schedule an immediate restart.
    /// Used by the watchdog when the process exits unexpectedly. Caps the
    /// number of consecutive unattended restarts so a wedged dsh (persistent
    /// port conflict, missing profile, etc.) surfaces as a failure instead of
    /// spin-looping forever.
    func restart(afterSeconds delay: TimeInterval = 1.0) {
        autorestartCleanup()
        restartCount += 1
        guard restartCount <= maxRestartAttempts else {
            transition(.failed("dsh 连续 \(maxRestartAttempts) 次自动重启失败，已停止重试。请检查端口占用或控制台日志。"))
            return
        }
        transition(.restarting(reason: "dsh 进程意外退出（第 \(restartCount)/\(maxRestartAttempts) 次）"))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startIfNeeded()
        }
    }

    // MARK: - Prepare

    private struct Runtime {
        let executableURL: URL
        let arguments: [String]
        /// PATH to hand the child (includes `node` when we exec a JS entry).
        let path: String
    }

    /// Resolve the `dsh` binary from the login/PATH shell and build args.
    private func prepareLaunch() throws -> (Runtime, URL?) {
        let dsh = try Self.resolveDshPath(javaScriptOK: true)
        let portArg = autoPort ? ["--port", "0"] : ["--port", String(config.port)]
        let args = ["--profile", "web", "--host", config.host] + portArg + config.extraArgs

        var executable = dsh
        var execArgs = args
        var extraPath: [String] = []

        // If dsh is a node script (npx shim or lib/bin.js), exec it via node
        // so we never depend on the child PATH resolving `env node`.
        if Self.isJavaScriptEntry(dsh.resolvingSymlinksInPath()) {
            if let node = Self.resolveNode() {
                executable = node
                // Pass the resolved script path (e.g. .../lib/bin.js) to node.
                execArgs = [dsh.resolvingSymlinksInPath().path] + args
                extraPath.append(node.deletingLastPathComponent().path)
            } else {
                throw DshError.notFound(
                    "dsh 是 node 脚本，但找不到 node。请确保已安装 Node.js，"
                    + "或把 node 所在目录加入 PATH。"
                )
            }
        }

        // Grow the child PATH: node dir (if any) + dsh dir + system essentials.
        var pathDirs: [String] = extraPath
        pathDirs.append(dsh.deletingLastPathComponent().path)
        pathDirs.append(contentsOf: ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"])

        // With auto-port the real URL is unknown until stdout arrives.
        let knownURL = autoPort ? nil : URL(string: "http://\(config.host):\(config.port)")!

        let runtime = Runtime(executableURL: executable, arguments: execArgs, path: pathDirs.joined(separator: ":"))
        return (runtime, knownURL)
    }

    /// Locate a usable `node` from env / npx shim / mise / homebrew.
    private static func resolveNode() -> URL? {
        if let n = ProcessInfo.processInfo.environment["DSH_NODE_BIN"], !n.isEmpty,
           FileManager.default.isExecutableFile(atPath: n) {
            return URL(fileURLWithPath: n)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/share/mise/installs/node/latest/bin/node",
            "\(home)/.nvm/current/bin/node",
            "\(home)/.bun/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Global lookup via login shell PATH.
        if let out = runShellCapture("/bin/zsh", "command -v node") {
            let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// Resolve the `dsh` executable, handling both real binaries and the
    /// npm-style `node_modules/.bin` script shims (symlinks into the installed
    /// package). Returns the URL to actually exec: if `DSH_BIN` or discovery
    /// points at a JS script, we exec it via `node`.
    private static func resolveDshPath(javaScriptOK: Bool = false) throws -> URL {
        if let env = ProcessInfo.processInfo.environment["DSH_BIN"], !env.isEmpty {
            let p = URL(fileURLWithPath: env)
            if exists(p) { return p }
        }
        // GUI apps under launchd do not inherit shell PATH. Probe login-shell
        // PATHs, then common package-manager bin dirs, then npx install roots.
        for dir in candidateBinDirs() {
            let p = URL(fileURLWithPath: dir).appendingPathComponent("dsh")
            if exists(p, allowScript: javaScriptOK) { return p }
        }
        // npx installs keep dsh under ~/.npm/_npx/<hash>/node_modules/.bin/dsh
        if let npxShim = try resolveNpxShim(javaScriptOK: javaScriptOK) {
            return npxShim
        }
        throw DshError.notFound(
            "请安装 `@deepseek-ai/dsh`（如 `npx -y @deepseek-ai/dsh --version`），"
            + "或通过环境变量 DSH_BIN 指定其完整路径（可指向 .bin/dsh 或 lib/bin.js），"
            + "再启动本应用。"
        )
    }

    /// Collect plausible `bin` dirs from login shells + node shims + runners.
    private static func candidateBinDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        for shell in ["/bin/zsh", "/bin/bash"] {
            if let out = runShellCapture(shell, "echo $PATH") {
                dirs.append(contentsOf: out.split(separator: ":").map(String.init))
            }
        }
        // Node toolchains and package managers
        dirs.append(contentsOf: [
            "\(home)/.local/share/mise/shims",
            "\(home)/.local/share/mise/installs/node/latest/bin",
            "\(home)/.nvm/current/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/.npm/node_modules/.bin",
            "\(home)/node_modules/.bin",
            "\(home)/.npx",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ])
        // Expand globs (mise version-pinned node dirs like node/22.22.3).
        let miseRoot = "\(home)/.local/share/mise/installs/node"
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: miseRoot) {
            for v in nodes where !v.hasPrefix(".") {
                dirs.append("\(miseRoot)/\(v)/bin")
            }
        }
        // de-dup, keep order, keep existing dirs only
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }

    /// npx caches dsh at ~/.npm/_npx/<id>/node_modules/.bin/dsh. Return the
    /// newest one if any.
    private static func resolveNpxShim(javaScriptOK: Bool) throws -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let npxRoot = "\(home)/.npm/_npx"
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) else {
            return nil
        }
        var found: [URL] = []
        for id in ids where !id.hasPrefix(".") {
            let shim = URL(fileURLWithPath: "\(npxRoot)/\(id)/node_modules/.bin/dsh")
            if exists(shim, allowScript: javaScriptOK) { found.append(shim) }
        }
        return found.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func runShellCapture(_ shell: String, _ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exists(_ url: URL, allowScript: Bool = false) -> Bool {
        // Follow symlinks: resolve the destination before the exec-bit check.
        let resolved = url.resolvingSymlinksInPath()
        if FileManager.default.isExecutableFile(atPath: resolved.path) {
            return true
        }
        // Tolerate JS scripts that exist (the exec path handles `node`).
        if allowScript, FileManager.default.fileExists(atPath: resolved.path), isJavaScriptEntry(resolved) {
            return true
        }
        return false
    }

    /// True when the file looks like a node/JS entry (`.js`/`.mjs`/`.cjs` or a
    /// `.bin` symlink that resolves into a JS entry).
    private static func isJavaScriptEntry(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["js", "mjs", "cjs"].contains(ext) { return true }
        // No extension (e.g. `.bin/dsh` without it being an executable binary):
        // sniff the first line for a `#!/usr/bin/env node` shebang.
        if let contents = try? String(contentsOf: url, encoding: .utf8),
           contents.hasPrefix("#!") && contents.contains("node") {
            return true
        }
        return false
    }

    // MARK: - Launch

    private func launch(executable: URL, arguments: [String], path: String) {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments

        // GUI app env is minimal; hand the child a composed PATH that lets
        // dsh find node, git, and its own toolchain.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard data.count > 0, let self, let line = String(data: data, encoding: .utf8) else { return }
            self.handleOutput(String(line))
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard data.count > 0, let self, let line = String(data: data, encoding: .utf8) else { return }
            self.handleError(String(line))
        }

        do {
            try p.run()
        } catch {
            transition(.failed("无法执行 \(executable.path)：\(error.localizedDescription)"))
            return
        }
        process = p
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasReady = { if case .ready = self.state { return true }; return false }()
                // A clean stop (App quit / explicit stop) sets state first.
                if wasReady {
                    self.restart()
                } else if self.process === proc {
                    self.transition(.idle)
                }
            }
        }
    }

    // MARK: - Output & readiness

    private func handleOutput(_ chunk: String) {
        onLog?(chunk)
        // autoPort: capture `dsh web: http://127.0.0.1:<port>`
        if autoPort {
            if let url = Self.localURL(in: chunk), let newPort = url.port {
                if self.seenPort == nil {
                    self.seenPort = newPort
                    beginReadinessPoll(finalURL: url, healthPort: newPort)
                }
            }
        }
    }

    private func handleError(_ chunk: String) {
        onLog?(chunk)
        if autoPort == false { return }
        if let url = Self.localURL(in: chunk), let newPort = url.port, self.seenPort == nil {
            self.seenPort = newPort
            beginReadinessPoll(finalURL: url, healthPort: newPort)
        }
    }

    private static func localURL(in text: String) -> URL? {
        // dsh prints:  dsh web: http://127.0.0.1:<port>  (and possibly a LAN line)
        let pattern = #"http:\/\/127\.0\.0\.1:(\d+)"#
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text),
              let url = URL(string: String(text[r])) else { return nil }
        return url
    }

    private func beginReadinessPoll(finalURL: URL, healthPort: Int) {
        readinessTimer?.invalidate()
        var attempts = 0
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.isHealthy(port: healthPort) {
                t.invalidate()
                self.restartCount = 0
                self.transition(.ready(finalURL))
            } else {
                attempts += 1
                if attempts >= Self.maxHealthAttempts {
                    t.invalidate()
                    let alive = self.process?.isRunning == true
                    if !alive {
                        self.transition(.failed("dsh 进程已退出。请检查上方日志。"))
                    } else if self.autoPort == true {
                        // Possibly not a boot; let it keep trying until URL/ready appears.
                        self.transition(.starting)
                    } else {
                        self.transition(.failed("HTTP 探活超时。"))
                    }
                }
            }
        }
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private static let maxHealthAttempts = 75 // ~30s at 0.4s

    private func awaitPrintedPort() {
        readinessTimer?.invalidate()
        var attempts = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            attempts += 1
            if self.seenPort != nil {
                t.invalidate() // health polling takes over
                return
            }
            if self.process?.isRunning == false {
                t.invalidate()
                self.transition(.failed("dsh 进程在输出地址前已退出。"))
            } else if attempts >= 80 {
                t.invalidate()
                self.transition(.failed("未捕获到 dsh web 的监听地址。"))
            }
        }
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func isHealthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { return false }
        return Self.isHealthy(url: url)
    }

    /// Lightweight connect probe: a 200-399 response on the root counts as up.
    private static func isHealthy(url: URL) -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.httpMethod = "HEAD"
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                ok = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        return ok
    }

    private func transition(_ s: State) {
        switch s {
        case .ready: readinessTimer?.invalidate()
        default: break
        }
        state = s
    }

    // MARK: - Teardown

    private func autorestartCleanup() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        readinessTimer?.invalidate()
    }

    private func stopQuietly() {
        readinessTimer?.invalidate()
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil   // stop the watchdog from respawning

        guard p.isRunning else {
            // Already dead; nothing to tear down.
            return
        }

        // Graceful termination with a bounded synchronous wait, so the child is
        // actually gone before the app exits (a bare async-after kill can be
        // dropped if the app process is already terminating).
        p.terminate()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            p.waitUntilExit()
            sem.signal()
        }
        // Wait up to ~2s for a clean SIGTERM exit, then escalate to SIGKILL.
        if sem.wait(timeout: .now() + 2.0) == .timedOut, p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            _ = sem.wait(timeout: .now() + 1.0)
        }
    }
}
