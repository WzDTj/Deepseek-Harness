# Workspace 多目录绑定改造设计

目标:让一个 workspace 从"绑定单个目录"变成"可绑定多个目录",并且沙箱的
`workspace-write` 边界同步扩展为该 workspace 的全部绑定目录。

## 1. 现状(改造前)

workspace 功能由以下包实现(全部为 `@deepseek-ai/dsh-*`,版本 0.1.0-rc.6):

| 包 | 角色 |
| --- | --- |
| `dsh-workspace` | Host 实体注册表 `ctx.workspaceRegistry`;记录 `{ path, title, sessionIds, createdAt, updatedAt }`;域 `workspace` v2,不变式:一个规范化路径只属于一个 workspace,会话 attach 校验 `canonical(cwd) === path` |
| `dsh-host-apiproxy` | `workspace.*` RPC(`list/create/rename/delete/insertBefore/insertSessionBefore/archiveSession`)与 zod schema;`session.create` 支持 `workspaceId` XOR `cwd` |
| `dsh-client-runtime` | 浏览器端 `ctx.workspaces` 服务(WorkspaceRuntime/Manager),`connectWorkspace` 按 `cwd === workspace.path` 复用空白会话,否则 `sessions.create({ workspaceId })` |
| `dsh-client-ui-workspace` | 侧边栏 WorkspacePicker / WorkspaceBrowser,slot:`sidebar.workspaces`、`conversation.hero.workspace`、两个 `directoryFlow` 洞 |
| `dsh-sandbox-policy` | `resolve()` 从 session cwd 派生单一 `workspaceRoot` |
| `dsh-sandbox` | `writableRoots(policy)` 把 `workspaceRoot` + `/tmp` + `tmpdir()` 拼成允许写根集合 |
| `dsh-sandbox-local` / `dsh-fs-sandbox` / `dsh-sandbox-windows-acl` | 执法端,按根集合放行(执法端已是"集合"模型) |

数据流:UI 选中 workspace → `connectWorkspace(workspaceId)` → host `session.create`
用 `workspace.path` 作为会话 cwd → `attachSession` 校验 cwd。沙箱每次调用
`resolve({session})` 用会话 cwd 作唯一写根。

## 2. 数据模型

workspace 记录从单路径改为有序目录列表(第一个为主目录):

```
{ paths: string[], title, sessionIds, createdAt, updatedAt }
```

不变式(在 v2 基础上泛化):

1. 每个规范化路径最多被一个 workspace 绑定(跨 workspace 唯一,`validateStoredState` 检查)。
2. `paths` 非空;移除最后一个目录被拒绝(workspace 至少持有一个目录)。
3. 会话归属:canonical(cwd) ∈ paths。attach 校验、`sessionIds` getter 过滤、bootstrap 分组都按集合判断。
4. 主目录 = `paths[0]`;移除主目录后顺位者顶上;`title` 默认值只在 create 时取主目录 basename,后续增删目录不改名。

持久化兼容(关键):域版本保持 v2 不 bump——存储层对版本不匹配是硬失败且没有迁移钩子
(`version-mismatch`)。方案:record schema 写成容忍旧行的 transform——
旧行 `{ path, ... }` 加载时归一化为 `{ paths: [path], ... }`,新行直接写 `paths`。
这样已有用户的 workspace 存储原地可用,新老行共存。

## 3. 各包改动

### 3.1 dsh-workspace(Host 实体)

- `spec.ts`:record schema 改 `paths`(transform 兼容旧 `path` 行);导出 schema 归一化后不含 `path`。
- `entity.ts`:
  - 新 getter `paths`;保留 `path` getter = `paths[0]`(兼容既有消费方)。
  - `sessionIds` getter 过滤:sessionPath ∈ paths。
  - `attachSession`:cwd ∈ paths 即通过。
  - `mutate` 内候选剪枝:改为按 paths 集合。
  - 新方法 `addDirectory(path)`:realpath 规范化 → 必须是存在的目录 → 已绑定则幂等 →
    跨 workspace 唯一性(经 registry 检查)→ append 到 paths。
  - 新方法 `removeDirectory(path)`:按存储值或 realpath 匹配 → 未绑定报错 →
    最后一个目录拒绝 → 从 paths 移除。
  - `hasDirectory(path)`:session.create 用,校验请求的 cwd 是否属于该 workspace。
  - `status()`:'ok' 当至少一个目录存在,否则 'missing-dir'。
- `index.ts`(registry):
  - `create` 不变(初始目录 → `paths: [canonical]`)。
  - `resolveByPath` 按 paths 集合匹配;新增同步 `findByPath(canonical)`(供沙箱策略同步查询)。
  - `createCanonical` / `bootstrap` / `validateStoredState` / `reportFilteredCandidates`
    全部从 `path` 改 `paths`(bootstrap 的 byPath 索引按每个路径建)。
  - 路径唯一性检查集中在一个 helper,`addDirectory` 与 `validateStoredState` 共用。

### 3.2 dsh-host-apiproxy

- `workspaceView` / `changedWorkspaceView`:输出 `paths`(新)与 `path`(主目录,兼容)。
- `workspaceViewSchema`:加 `paths: z.array(z.string()).min(1)`,保留 `path`。
- 新 RPC(挂进 method map + schema):
  - `workspace.addDirectory({ workspaceId, path })` → `{ workspace }`;错误:
    `workspace-not-found` / `workspace-invalid-path` / `workspace-path-conflict`。
  - `workspace.removeDirectory({ workspaceId, path })` → `{ workspace }`;错误:
    `workspace-not-found` / `workspace-directory-not-bound` / `workspace-last-directory`。
- `session.create`:放开 schema 的 XOR refine,允许 `workspaceId` 与 `cwd` 同传;
  handler 用 `workspace.hasDirectory(cwd)` 校验,合法则用该 cwd,非法返回
  `workspace-directory-not-bound`;缺省仍用 `workspace.path`。

### 3.3 dsh-client-runtime(浏览器 workspaces 服务)

- Workspace/Manager:view 透传 `paths`(changed-frame upsert 跟随 record schema 自动兼容)。
- `connectWorkspace(workspaceId, cwd?)`:复用空白会话时按 `cwd ?? workspace.path` 匹配;
  新建走 `sessions.create({ workspaceId, cwd? })`。
- `startSession(workspaceId, cwd?)` 透传。
- 新增 `addDirectory(workspaceId, path)` / `removeDirectory(workspaceId, path)`。

### 3.4 dsh-client-ui-workspace

- WorkspaceBrowser:
  - workspace 行悬停 tooltip 列出全部目录。
  - workspace 右键/悬停菜单新增"添加目录…"(复用 `sidebar.workspaces.directoryFlow` 洞)。
  - paths.length > 1 时提供"移除目录…"子菜单(逐目录列出,主目录标记)。
  - 多目录 workspace 的"新会话"操作弹出目录选择(单目录保持原直接行为)。
- 文案补 zh/en 词典条目。

### 3.5 沙箱(workspace-write 边界 = 全部绑定目录)

- `dsh-sandbox-policy`:
  - `resolve()`:有 session cwd 时,若 workspaceRegistry(可选 `ctx.get`)里存在
    绑定该规范化 cwd 的 workspace,则 `workspaceRoots` = 该 workspace 全部 paths
    (规范化);否则 = [cwd]。无 session 用部署回退根。
  - 保留 `workspaceRoot`(主根,兼容 tool-bash 的 workdir 默认、terminal cwd、
    fs 相对路径解析),新增 `workspaceRoots` 字段。
  - `renderPolicyContext` 展示全部根。
- `dsh-sandbox`: `writableRoots(policy)` 改用 `policy.workspaceRoots ?? [policy.workspaceRoot]`。
- `dsh-sandbox-local`(macOS seatbelt / bwrap 路径):bind 与 readWrite 授权覆盖全部根。
- `dsh-sandbox-windows-acl`:每个根物化一个 grant(保持平台对齐)。
- `dsh-tool-cordis` 里 sandboxPolicy 的描述文案同步(展示性)。

注意:读写放行的扩展只发生在会话 cwd 命中某 workspace 的绑定目录时;未分组会话
行为与今天完全一致。

## 4. 测试与验证

- 更新 dsh-workspace 单测:legacy `path` 行归一化、add/remove、唯一性冲突、最后一目录拒绝。
- 更新 sandbox 相关单测:多根 allow-list。
- 构建产物:受影响的 host 包 lib 与 client 包 `lib/client.js` 拷贝进本机
  npm 安装树(`~/.local/share/mise/installs/node/22.22.3/lib/node_modules/@deepseek-ai/dsh/node_modules/...`)。
  client 包由 `/plugins/<id>/client.js` 独立分发(带 rev 缓存),无需重建 apps/web shell。
- 重启 dsh(经 macOS 壳或 `dsh web`),浏览器刷新验证:
  1. 旧 workspace 记录仍可打开(归一化);
  2. 添加第二个目录 → 显示、可移除;
  3. 新会话可选任一目录作 cwd;
  4. 在目录 A 的会话里写目录 B 的文件被放行(多根边界)。

## 5. 目录归属

- 源码:`dsh-src/`(upstream `deepseek-ai/deepseek-harness` 浅克隆 + 本地改动)。
- 本机生效:替换 npm 安装树内对应包的 `lib` 产物。
