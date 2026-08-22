# DeepSeek Harness Desktop（macOS App）

## 背景

DeepSeek Harness 的 `dsh web` 是一个跑在本地浏览器里的助手界面，但日常使用它
需要一直开着终端、手动启动进程。这个项目就用原生 **SwiftUI** 做了一个 macOS
套壳，把 `dsh web` 封装进一个内嵌的 `WKWebView`，像普通 App 一样即开即用。

## 依赖与运行方式

应用是**非自包含**的：不打包 Node 或 `@deepseek-ai/dsh` 代码树。设置窗口中的
**运行环境**页支持两种启动方式：

1. **已安装 dsh**（默认）——启动宿主机上的 `dsh --profile web`。
2. **源码运行**——选择 DeepSeek Harness 源码仓库根目录，应用从该目录执行官方
   的 `pnpm dsh web` 命令。源码目录必须包含 `package.json`；首次使用前，在仓库根目录
   按官方流程完成依赖安装和构建：

   ```sh
   pnpm install
   pnpm run build
   ```

   应用启动时会以该目录为工作目录执行 `pnpm dsh web --no-open ...`，并把本地端口
   参数传给 `web` 子命令。`--no-open` 是为了让界面只在 App 的 `WKWebView` 中打开。

已安装 `dsh` 模式下，如果遇到 _“找不到可用的 dsh 命令”_，请检查 `which dsh` /
`npx @deepseek-ai/dsh --version`，或把应用指向确切的二进制：

```sh
export DSH_BIN="$HOME/.npm/_npx/<hash>/node_modules/.bin/dsh"
```

## 配置

### 设置窗口（推荐）

从菜单 **DeepSeek Harness Desktop › 设置…**（`⌘,`）打开“运行环境”设置页，可以在同一页完成：

- 选择“已安装 dsh”或“源码运行”；源码运行时选择仓库根目录，App 会按官方方式执行
  `pnpm dsh web`。
- 设置监听端口，或开启“自动选择空闲端口”（改用 `--port 0`，启动时自动挑选可用端口，
  避免端口冲突）。
- 手动指定 `dsh` / `pnpm` / `node` 的绝对路径，并用“状态诊断”查看当前解析结果。路径和
  端口编辑完成后点击“应用并重启”才会生效；清空路径字段即可恢复自动检测。

设置会被持久化保存。**设置窗口中的值优先于环境变量**；未设置时回退到环境变量，
再回退到自动检测。

### 环境变量（回退）

| 变量           | 默认值      | 含义                                                     |
| -------------- | ----------- | -------------------------------------------------------- |
| `DSH_PORT`     | `3080`      | 子进程 `dsh web` 绑定的端口 / WebView 加载的端口。       |
| `DSH_HOST`     | `127.0.0.1` | 绑定主机。请保持回环地址（dsh 设计上会拒绝 `0.0.0.0`）。 |
| `DSH_AUTO_PORT`| `0`         | 非 0 时使用 `--port 0` 自动挑选空闲端口。                |
| `DSH_BIN`      | _(自动)_    | `dsh` 的绝对路径（shim 或 `lib/bin.js`）。               |
| `DSH_NODE_BIN` | _(自动)_    | `node` 的绝对路径。                                      |
| `DSH_PNPM_BIN` | _(自动)_    | 源码模式使用的 `pnpm` 绝对路径。                         |
