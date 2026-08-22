import Combine
import Foundation

enum DshLaunchMode: String, CaseIterable, Identifiable {
    case installed
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed: return "已安装 dsh"
        case .source: return "源码运行"
        }
    }
}

/// User-editable settings backed by `UserDefaults`, exposed as KVO-observable
/// published values so the UI and the harness `Config` share one source of
/// truth.
///
/// Precedence (highest first):
///   1. an explicit value the user set in the Settings window;
///   2. the environment-variable fallback (`DSH_PORT`, `DSH_AUTO_PORT`,
///      `DSH_BIN`, `DSH_NODE_BIN`, `DSH_PNPM_BIN`) documented in the README;
///   3. the auto-detected default (port 3080, resolved `dsh`/`node`/`pnpm`).
///
/// Because `UserDefaults` has no "unset" state, presence is tracked with
/// `object(forKey:) != nil`. Clearing a path field in the UI sets it back to
/// `nil` so auto-detection takes over again.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Published values

    /// Whether to launch the installed CLI or the selected repository from source.
    @Published var launchMode: DshLaunchMode? {
        didSet { defaults.setIfPresent(launchMode?.rawValue, forKey: Keys.launchMode) }
    }

    /// Effective listening port. `nil` means "use `DSH_PORT` env, else 3080".
    @Published var port: Int? {
        didSet { defaults.setIfPresent(port, forKey: Keys.port) }
    }

    /// `true` = auto-pick a free port (`--port 0`). `nil` = use `port`.
    @Published var autoPort: Bool? {
        didSet { defaults.setIfPresent(autoPort, forKey: Keys.autoPort) }
    }

    /// Absolute `dsh` path override. `nil`/empty = auto-detect.
    @Published var dshPath: String? {
        didSet { defaults.setIfPresent(nilIfEmpty(dshPath), forKey: Keys.dshPath) }
    }

    /// Absolute `node` path override. `nil`/empty = auto-detect.
    @Published var nodePath: String? {
        didSet { defaults.setIfPresent(nilIfEmpty(nodePath), forKey: Keys.nodePath) }
    }

    /// Source repository root. It must contain the official repository
    /// `package.json` and is used as the child process working directory.
    @Published var sourcePath: String? {
        didSet { defaults.setIfPresent(nilIfEmpty(sourcePath), forKey: Keys.sourcePath) }
    }

    /// Optional absolute `pnpm` path override used by source mode.
    @Published var pnpmPath: String? {
        didSet { defaults.setIfPresent(nilIfEmpty(pnpmPath), forKey: Keys.pnpmPath) }
    }

    // MARK: - Resolved (point-in-time) values for the harness

    var resolvedLaunchMode: DshLaunchMode {
        launchMode ?? .installed
    }

    /// The effective port, env fallback applied.
    var resolvedPort: Int {
        if let port { return port }
        return Self.envInt("DSH_PORT") ?? 3080
    }

    var resolvedAutoPort: Bool {
        if let autoPort { return autoPort }
        return Self.envInt("DSH_AUTO_PORT").map { $0 != 0 } ?? false
    }

    var resolvedDshPath: String? {
        if let p = dshPath, !p.isEmpty { return p }
        return Self.envNonEmpty("DSH_BIN")
    }

    var resolvedNodePath: String? {
        if let p = nodePath, !p.isEmpty { return p }
        return Self.envNonEmpty("DSH_NODE_BIN")
    }

    var resolvedSourcePath: String? {
        guard let p = sourcePath, !p.isEmpty else { return nil }
        return p
    }

    var resolvedPnpmPath: String? {
        if let p = pnpmPath, !p.isEmpty { return p }
        return Self.envNonEmpty("DSH_PNPM_BIN")
    }

    // MARK: - Init

    private let defaults: UserDefaults
    private enum Keys {
        static let launchMode = "settings.launchMode"
        static let port = "settings.port"
        static let autoPort = "settings.autoPort"
        static let dshPath = "settings.dshPath"
        static let nodePath = "settings.nodePath"
        static let sourcePath = "settings.sourcePath"
        static let pnpmPath = "settings.pnpmPath"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Assign through storage directly to avoid re-persisting on load.
        if let raw = defaults.string(forKey: Keys.launchMode),
           let mode = DshLaunchMode(rawValue: raw) {
            self._launchMode = Published(initialValue: mode)
        } else {
            self._launchMode = Published(initialValue: nil)
        }
        if let p = defaults.object(forKey: Keys.port) as? NSNumber {
            self._port = Published(initialValue: p.intValue)
        } else {
            self._port = Published(initialValue: nil)
        }
        if let ap = defaults.object(forKey: Keys.autoPort) as? NSNumber {
            self._autoPort = Published(initialValue: ap.boolValue)
        } else if let raw = defaults.string(forKey: Keys.autoPort) {
            self._autoPort = Published(initialValue: (raw as NSString).boolValue)
        } else {
            self._autoPort = Published(initialValue: nil)
        }
        self._dshPath = Published(initialValue: defaults.string(forKey: Keys.dshPath))
        self._nodePath = Published(initialValue: defaults.string(forKey: Keys.nodePath))
        self._sourcePath = Published(initialValue: defaults.string(forKey: Keys.sourcePath))
        self._pnpmPath = Published(initialValue: defaults.string(forKey: Keys.pnpmPath))
    }

    // MARK: - Helpers

    private func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func envInt(_ key: String) -> Int? {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init)
    }

    private static func envNonEmpty(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty == false) ? v : nil
    }
}

private extension UserDefaults {
    func setIfPresent<T>(_ value: T?, forKey key: String) {
        if let value {
            set(value, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }
}
