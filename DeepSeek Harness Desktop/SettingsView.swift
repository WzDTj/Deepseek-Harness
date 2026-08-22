import AppKit
import SwiftUI

/// Preferences for the local Harness runtime.
///
/// The view intentionally stages edits locally. Path fields are not persisted
/// on every keystroke, so a partially typed path cannot restart the child
/// process with an invalid configuration.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var launchModeDraft: DshLaunchMode = .installed
    @State private var autoPortDraft = false
    @State private var portText = ""
    @State private var dshPathDraft = ""
    @State private var nodePathDraft = ""
    @State private var sourcePathDraft = ""
    @State private var pnpmPathDraft = ""
    @State private var portError: String?
    @State private var sourceError: String?
    @State private var resolution: DshProcessManager.ResolutionPreview?
    @State private var isLoadingPreview = false
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                runtimeSection
                serverSection
                toolchainSection
                diagnosticSection
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .frame(width: 620, height: 680)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title)
        .onAppear {
            syncDrafts()
            WindowChrome.hideTitleBar(for: "DeepSeek Harness Desktop Settings")
        }
        .confirmationDialog(
            "恢复默认设置？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认值", role: .destructive, action: resetSettings)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清除端口、运行方式和所有路径覆盖，并回到自动检测。")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text("运行环境")
                    .font(.system(size: 22, weight: .semibold))
                Text("配置本地 Harness 的启动方式、端口和工具链。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeSection: some View {
        settingsSection(
            title: "启动方式",
            subtitle: "选择 App 要启动的 Harness 来源。"
        ) {
            Picker("启动方式", selection: $launchModeDraft) {
                ForEach(DshLaunchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: launchModeDraft) { refreshPreview() }

            Text(launchModeDraft == .source
                 ? "从源码仓库根目录执行官方的 pnpm dsh web 命令。"
                 : "使用宿主机已安装的 dsh 命令；留空路径即可自动检测。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if launchModeDraft == .source {
                sourcePathEditor
            }
        }
    }

    private var serverSection: some View {
        settingsSection(
            title: "服务",
            subtitle: "控制本地 Web 服务的监听端口。"
        ) {
            Toggle(isOn: $autoPortDraft) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动选择空闲端口")
                    Text("使用 --port 0，避免端口被其他进程占用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !autoPortDraft {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("监听端口")
                        .frame(width: 84, alignment: .leading)
                    TextField("3080", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .onSubmit(applyChanges)
                        .onChange(of: portText) { portError = nil }
                    Text("1–65535")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let portError {
                    Label(portError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.leading, 96)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("启动地址")
                    .frame(width: 84, alignment: .leading)
                Text(autoPortDraft
                     ? "http://127.0.0.1:<启动时确定>"
                     : "http://127.0.0.1:\(portText.isEmpty ? "3080" : portText)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var toolchainSection: some View {
        settingsSection(
            title: "工具链",
            subtitle: "留空表示自动检测；路径只在点击“应用并重启”后生效。"
        ) {
            if launchModeDraft == .installed {
                pathField(
                    title: "dsh",
                    help: "可执行文件、shim 或 lib/bin.js。",
                    text: $dshPathDraft
                )
            } else {
                pathField(
                    title: "pnpm",
                    help: "源码模式按官方方式使用 pnpm dsh web。",
                    text: $pnpmPathDraft
                )
            }

            pathField(
                title: "node",
                help: "运行 dsh 或 pnpm 所需的 Node.js。",
                text: $nodePathDraft
            )
        }
    }

    private var diagnosticSection: some View {
        settingsSection(
            title: "状态诊断",
            subtitle: "只检查路径是否可解析，不代替源码依赖安装或构建。"
        ) {
            HStack(spacing: 8) {
                Label(diagnosticTitle, systemImage: diagnosticIcon)
                    .foregroundStyle(diagnosticColor)
                Spacer()
                if isLoadingPreview {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("重新检测", action: refreshPreview)
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(diagnosticRows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Text(row.value)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(alignment: .center, spacing: 12) {
                if hasPendingChanges {
                    Label("有未应用的更改", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("设置会保存在本机；应用后服务会重启。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("恢复默认值", role: .destructive) {
                    showResetConfirmation = true
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Spacer()
                Button("撤销更改", action: syncDrafts)
                    .disabled(!hasPendingChanges)
                Button("应用并重启", action: applyChanges)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasPendingChanges)
            }
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private var sourcePathEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("源码仓库")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                TextField("选择包含 package.json 的仓库根目录", text: $sourcePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: sourcePathDraft) {
                        sourceError = nil
                    }
                Button("选择…", action: chooseSourceDirectory)
            }
            Text("首次使用前，请在仓库根目录完成 pnpm install 和 pnpm run build。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sourceError {
                Label(sourceError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func pathField(title: String, help: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .frame(width: 58, alignment: .leading)
                TextField("自动检测", text: text)
                    .textFieldStyle(.roundedBorder)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 70)
        }
    }

    // MARK: - Drafts and actions

    private var hasPendingChanges: Bool {
        launchModeDraft != settings.resolvedLaunchMode
            || autoPortDraft != settings.resolvedAutoPort
            || portDraftDiffers
            || nilIfBlank(dshPathDraft) != settings.dshPath
            || nilIfBlank(nodePathDraft) != settings.nodePath
            || nilIfBlank(sourcePathDraft) != settings.sourcePath
            || nilIfBlank(pnpmPathDraft) != settings.pnpmPath
    }

    private var portDraftDiffers: Bool {
        guard !autoPortDraft else { return false }
        return portText.trimmingCharacters(in: .whitespacesAndNewlines) != String(settings.resolvedPort)
    }

    private func syncDrafts() {
        launchModeDraft = settings.resolvedLaunchMode
        autoPortDraft = settings.resolvedAutoPort
        portText = String(settings.resolvedPort)
        dshPathDraft = settings.dshPath ?? ""
        nodePathDraft = settings.nodePath ?? ""
        sourcePathDraft = settings.sourcePath ?? ""
        pnpmPathDraft = settings.pnpmPath ?? ""
        portError = nil
        sourceError = nil
        refreshPreview()
    }

    private func applyChanges() {
        let portValue: Int?
        if !autoPortDraft {
            guard let value = validPort else { return }
            portValue = value
        } else {
            portValue = nil
        }

        if launchModeDraft == .source {
            guard let error = validateSourcePath() else {
                sourceError = nil
                applySettings(port: portValue)
                return
            }
            sourceError = error
            return
        }

        applySettings(port: portValue)
    }

    private func applySettings(port: Int?) {
        settings.launchMode = launchModeDraft
        if let port {
            settings.port = port
        }
        settings.autoPort = autoPortDraft
        settings.dshPath = nilIfBlank(dshPathDraft)
        settings.nodePath = nilIfBlank(nodePathDraft)
        settings.sourcePath = nilIfBlank(sourcePathDraft)
        settings.pnpmPath = nilIfBlank(pnpmPathDraft)
        sourceError = nil
        refreshPreview()
    }

    private func resetSettings() {
        settings.launchMode = nil
        settings.port = nil
        settings.autoPort = nil
        settings.dshPath = nil
        settings.nodePath = nil
        settings.sourcePath = nil
        settings.pnpmPath = nil
        syncDrafts()
    }

    private var validPort: Int? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(value) else {
            portError = "请输入 1–65535 之间的端口号"
            return nil
        }
        portError = nil
        return value
    }

    private func validateSourcePath() -> String? {
        let raw = sourcePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "请选择源码仓库根目录。"
        }

        let url = URL(fileURLWithPath: raw).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "目录不存在：\(raw)"
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path) else {
            return "目录中找不到 package.json。"
        }
        return nil
    }

    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 DeepSeek Harness 源码仓库根目录"

        if panel.runModal() == .OK, let url = panel.url {
            sourcePathDraft = url.path
            sourceError = validateSourcePath()
            refreshPreview()
        }
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Diagnostics

    private var diagnosticTitle: String {
        guard let resolution else { return "尚未检测" }
        switch resolution.launchMode {
        case .installed:
            return resolution.dshError == nil && resolution.nodePath != nil
                ? "已解析已安装工具链"
                : "需要配置已安装工具链"
        case .source:
            return resolution.sourceError == nil
                && resolution.pnpmError == nil
                && resolution.nodePath != nil
                ? "已解析源码工具链"
                : "需要配置源码工具链"
        }
    }

    private var diagnosticIcon: String {
        diagnosticTitle.hasPrefix("已") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var diagnosticColor: Color {
        diagnosticTitle.hasPrefix("已") ? .green : .orange
    }

    private struct DiagnosticRow: Hashable {
        let label: String
        let value: String
    }

    private var diagnosticRows: [DiagnosticRow] {
        guard let resolution else {
            return [DiagnosticRow(label: "状态", value: "点击重新检测")]
        }

        switch resolution.launchMode {
        case .installed:
            return [
                DiagnosticRow(label: "dsh", value: resolution.dshError ?? resolution.dshPath ?? "未找到"),
                DiagnosticRow(label: "node", value: resolution.nodePath ?? "未找到")
            ]
        case .source:
            return [
                DiagnosticRow(label: "源码", value: resolution.sourceError ?? resolution.sourcePath ?? "未选择"),
                DiagnosticRow(label: "pnpm", value: resolution.pnpmError ?? resolution.pnpmPath ?? "未找到"),
                DiagnosticRow(label: "node", value: resolution.nodePath ?? "未找到")
            ]
        }
    }

    private func refreshPreview() {
        isLoadingPreview = true
        resolution = DshProcessManager.shared.resolutionPreview(
            launchMode: launchModeDraft,
            overrideSource: nilIfBlank(sourcePathDraft),
            overrideDsh: nilIfBlank(dshPathDraft),
            overridePnpm: nilIfBlank(pnpmPathDraft),
            overrideNode: nilIfBlank(nodePathDraft)
        )
        isLoadingPreview = false
    }
}
