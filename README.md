# Deepseek Harness (macOS 套壳)

A native macOS **SwiftUI** app that wraps the DeepSeek Harness `dsh web` browser
interface in an embedded `WKWebView`. The window is a **clean WebView with no
toolbar/address bar**; the harness **auto-starts when the window appears and
auto-stops on quit**. Under the hood it spawns a child
`dsh --profile web --host 127.0.0.1 --port 3080`, waits until the endpoint is
healthy, then loads it. Before spawning, the app **probes the configured port
and reuses an already-running `dsh web`** (e.g. one started via `npx` or the
browser) instead of failing with `EADDRINUSE`; a watchdog restarts a crashed
child, capped at 3 attempts so a wedged dsh surfaces as a failure instead of
spin-looping.

## Project layout

```
Deepseek Harness.xcodeproj/       # standard Xcode project
Deepseek Harness/
  DeepseekHarnessApp.swift        # @main app entry + window + WKWebView + controller
  DshProcessManager.swift         # dsh child-process lifecycle (launch/health/stop)
  BrandResources/whale_user.svg   # source vector of the app icon (whale logo)
  Assets.xcassets/AppIcon.appiconset/   # compiled app icon (all macOS sizes)
```

## Runtime dependencies (not self-contained)

The app shells out to a host `dsh` install. It does **not** bundle Node or the
`@deepseek-ai/dsh` tree. On first start it resolves both:

- **dsh** — probed in order:
  1. `DSH_BIN` env var (absolute path),
  2. the login-shell `$PATH`,
  3. `~/.npm/_npx/*/node_modules/.bin/dsh` (npx installs),
  4. common package-manager bin dirs (`~/.local/share/mise/shims`,
     `~/.bun/bin`, `~/Library/pnpm`, Homebrew, …).
- **node** — because `dsh` ships as a node script (`lib/bin.js`), the app execs
  it via node, resolved from `DSH_NODE_BIN`, mise/nvm/bun/Homebrew, or the
  login shell.

If you get *“找不到可用的 dsh 命令”*, check `which dsh` / `npx @deepseek-ai/dsh
--version`, or point the app at the exact binary:

```sh
export DSH_BIN="$HOME/.npm/_npx/<hash>/node_modules/.bin/dsh"
```

## Configuration (launch environment)

| Variable | Default | Meaning |
|---|---|---|
| `DSH_PORT` | `3080` | Port the child `dsh web` binds / the WebView loads. |
| `DSH_HOST` | `127.0.0.1` | Bind host. Keep loopback (dsh rejects `0.0.0.0` by design). |
| `DSH_BIN` | *(auto)* | Absolute path to `dsh` (shim or `lib/bin.js`). |
| `DSH_NODE_BIN` | *(auto)* | Absolute path to `node`. |

> The WebView talks to `http://127.0.0.1:<port>` over a loopback Host header,
> which dsh's browser-trust fence accepts.

## Build & run

Open `Deepseek Harness.xcodeproj` in Xcode and ⌘R on the `Deepseek Harness`
scheme, or:

```sh
xcodebuild -project "Deepseek Harness.xcodeproj" \
           -scheme "Deepseek Harness" -configuration Debug build
```

> **App Sandbox is disabled** on purpose: a sandboxed app cannot spawn the
> external `dsh` child process.
