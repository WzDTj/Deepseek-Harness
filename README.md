# Deepseek Harness（macOS App）

## 背景

DeepSeek Harness 的 `dsh web` 是一个跑在本地浏览器里的助手界面，但日常使用它
需要一直开着终端、手动启动进程。这个项目就用原生 **SwiftUI** 做了一个 macOS
套壳，把 `dsh web` 封装进一个内嵌的 `WKWebView`，像普通 App 一样即开即用。

## 依赖

应用是**非自包含**的：需要调用宿主机器上已安装的 `dsh`，**不打包 Node，也不
打包 `@deepseek-ai/dsh` 代码树**。首次启动时会自动解析这两者：

- **dsh** —— 按以下顺序探测：
  1. `DSH_BIN` 环境变量（绝对路径），
  2. 登录 shell 的 `$PATH`，
  3. `~/.npm/_npx/*/node_modules/.bin/dsh`（npx 安装产物），
  4. 常见的包管理器 bin 目录（`~/.local/share/mise/shims`、`~/.bun/bin`、
     `~/Library/pnpm`、Homebrew 等）。
- **node** —— 因为 `dsh` 以 node 脚本发布（`lib/bin.js`），应用会通过 node 来
  执行它。node 由 `DSH_NODE_BIN`、mise / nvm / bun / Homebrew，或登录 shell
  解析得到。

如果遇到 _“找不到可用的 dsh 命令”_，请检查 `which dsh` / `npx @deepseek-ai/dsh
--version`，或把应用指向确切的二进制：

```sh
export DSH_BIN="$HOME/.npm/_npx/<hash>/node_modules/.bin/dsh"
```

## 配置

通过启动环境变量配置：

| 变量           | 默认值      | 含义                                                     |
| -------------- | ----------- | -------------------------------------------------------- |
| `DSH_PORT`     | `3080`      | 子进程 `dsh web` 绑定的端口 / WebView 加载的端口。       |
| `DSH_HOST`     | `127.0.0.1` | 绑定主机。请保持回环地址（dsh 设计上会拒绝 `0.0.0.0`）。 |
| `DSH_BIN`      | _(自动)_    | `dsh` 的绝对路径（shim 或 `lib/bin.js`）。               |
| `DSH_NODE_BIN` | _(自动)_    | `node` 的绝对路径。                                      |
