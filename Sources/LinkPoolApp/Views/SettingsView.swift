import LinkPoolCore
import SwiftUI
import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                portalCard
                sessionCard
                appearanceCard
                dataCard
                aboutCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("设置")
    }

    private var portalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "门户", subtitle: "选择学校使用的认证协议，地址可按部署调整")
                Picker("协议", selection: $model.config.portal.kind) {
                    ForEach(PortalKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .onChange(of: model.config.portal.kind) { _, _ in model.persist() }

                LabeledContent("门户地址") {
                    TextField("", text: Binding(
                        get: { model.config.portal.baseURL.absoluteString },
                        set: { if let url = URL(string: $0) { model.config.portal.baseURL = url } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: model.config.portal.baseURL) { _, _ in model.persist() }
                }

                if model.config.portal.kind == .huaweiAC {
                    LabeledContent("登录接口") {
                        TextField("", text: $model.config.portal.huaweiLoginPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onChange(of: model.config.portal.huaweiLoginPath) { _, _ in model.persist() }
                    }
                    LabeledContent("联网探测") {
                        TextField("", text: $model.config.portal.captiveCheckURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                            .onChange(of: model.config.portal.captiveCheckURL) { _, _ in model.persist() }
                    }
                    Text("华为 AC 登录：POST 表单到登录接口，密码用毫秒时间戳做 RC4 加密；联网探测返回 204 视为已在线。")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    LabeledContent("入口 ac_id") {
                        TextField("", text: $model.config.portal.entryACID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: model.config.portal.entryACID) { _, _ in model.persist() }
                    }
                    LabeledContent("默认 ac_id") {
                        TextField("", text: $model.config.portal.defaultACID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: model.config.portal.defaultACID) { _, _ in model.persist() }
                    }
                    Text("真实的 ac_id 在登录页的 CONFIG 中；LinkPool 会优先自动发现，失败才使用默认值。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var sessionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "会话", subtitle: "健康检查与失败退避")
                Stepper("检查间隔：\(Int(model.config.session.checkInterval)) 秒",
                        value: $model.config.session.checkInterval, in: 10...300, step: 10)
                    .onChange(of: model.config.session.checkInterval) { _, _ in model.persist() }
                Stepper("初始退避：\(Int(model.config.session.initialBackoff)) 秒",
                        value: $model.config.session.initialBackoff, in: 5...120, step: 5)
                    .onChange(of: model.config.session.initialBackoff) { _, _ in model.persist() }
                Stepper("最大退避：\(Int(model.config.session.maxBackoff)) 秒",
                        value: $model.config.session.maxBackoff, in: 30...900, step: 30)
                    .onChange(of: model.config.session.maxBackoff) { _, _ in model.persist() }
                Stepper("失败阈值：\(model.config.session.failureThreshold) 次",
                        value: $model.config.session.failureThreshold, in: 1...10)
                    .onChange(of: model.config.session.failureThreshold) { _, _ in model.persist() }
            }
        }
    }

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "外观与启动")
                Toggle("在菜单栏显示实时速度", isOn: $model.config.showSpeedInMenuBar)
                    .onChange(of: model.config.showSpeedInMenuBar) { _, _ in model.persist() }
                Toggle("登录时启动", isOn: Binding(
                    get: { model.config.launchAtLogin },
                    set: { newValue in
                        model.config.launchAtLogin = newValue
                        if let error = LaunchAtLogin.set(newValue) {
                            launchError = error
                        } else {
                            launchError = nil
                            model.persist()
                        }
                    }
                ))
                if let launchError {
                    Text("无法设置登录项：\(launchError)（需要以 .app 方式运行）")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var dataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "数据", subtitle: "配置在 Application Support，密码在钥匙串")
                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(appSupportDirectory)
                    } label: {
                        Label("打开配置目录", systemImage: "folder")
                    }
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logDirectory)
                    } label: {
                        Label("打开日志目录", systemImage: "doc.text.magnifyingglass")
                    }
                }
                Text("删除配置目录中的 config.json 会重置所有账号与链路；钥匙串条目需要手动删除。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "关于 LinkPool", subtitle: "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1") · 原生 SwiftUI · 无第三方依赖")
                Text("LinkPool 只在你主动操作时登录校园网账号，不会自动注销会话，也不会绕过学校的安全策略。请仅使用你拥有或获得明确授权的账号。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LinkPool", isDirectory: true)
    }

    private var logDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
    }
}
