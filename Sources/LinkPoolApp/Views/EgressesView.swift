import LinkPoolCore
import SwiftUI

struct EgressesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Egress?
    @State private var showEditor = false
    @State private var pendingDelete: Egress?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                configuredSection
                detectedSection
                note
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("链路")
        .sheet(isPresented: $showEditor) {
            if let editing {
                EgressEditorView(egress: editing) { saved in
                    model.saveEgress(saved)
                }
            }
        }
        .confirmationDialog("移除链路？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { egress in
            Button("移除 \(egress.name)", role: .destructive) {
                model.deleteEgress(egress)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("只会从 LinkPool 中移除，不会注销或删除系统里的 IP 地址。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(text: "上行链路", subtitle: "每条链路 = 一个源 IP = 一个校园网会话")
            Spacer()
            Button {
                editing = Egress(name: "", interfaceName: model.interfaces.first?.name ?? "en0",
                                 localAddress: model.interfaces.first?.primaryIPv4?.description ?? "")
                showEditor = true
            } label: {
                Label("添加链路", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private var configuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.config.egresses.isEmpty {
                Card {
                    Text("还没有配置链路。在下面的「可用网卡」中选择一个地址添加。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.config.egresses) { egress in
                    egressRow(egress)
                }
            }
        }
    }

    private func egressRow(_ egress: Egress) -> some View {
        let snapshot = model.snapshot(for: egress)
        return Card(padding: 15) {
            HStack(alignment: .top, spacing: 12) {
                IconBubble(systemName: egress.kind == .alias ? "square.stack.3d.up.fill" : "cable.connector",
                           tint: snapshot.phase == .online ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(egress.name).font(.callout.weight(.semibold))
                        PhaseBadge(phase: snapshot.phase)
                        if !egress.isEnabled { Text("已停用").font(.caption2).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 6) {
                        Text(egress.localAddress).monospaced()
                        Text("·")
                        Text(egress.interfaceName)
                        Text("·")
                        Text(egress.kind.displayName)
                        Text("· 权重 \(egress.weight)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Label(model.account(id: egress.accountID)?.name ?? "未绑定账号", systemImage: "person")
                        if egress.autoLogin { Label("自动登录", systemImage: "bolt.fill").foregroundStyle(.orange) }
                        if let error = snapshot.lastError, snapshot.phase != .online {
                            Text(error).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(Formatters.speed(model.speed(for: egress).down), systemImage: "arrow.down")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                        Label(Formatters.speed(model.speed(for: egress).up), systemImage: "arrow.up")
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.teal)
                    }
                    HStack(spacing: 6) {
                        Button("登录") { model.login(egress: egress) }
                            .controlSize(.small)
                        Menu {
                            Button("编辑") { editing = egress; showEditor = true }
                            Button(egress.isEnabled ? "停用" : "启用") {
                                var copy = egress
                                copy.isEnabled.toggle()
                                model.saveEgress(copy)
                            }
                            Divider()
                            Button("移除", role: .destructive) { pendingDelete = egress }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }
            }
        }
    }

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "可用网卡", subtitle: "已配置链路以外的地址也可以直接添加")
                Spacer()
                Button {
                    model.refreshInterfaces()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.link)
            }
            ForEach(model.interfaces) { iface in
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: iface.isWireless ? "wifi" : "cable.connector")
                                .foregroundStyle(Theme.accent)
                            Text(iface.displayName).font(.callout.weight(.medium))
                            Text(iface.name).font(.caption).foregroundStyle(.secondary).monospaced()
                            if iface.isDefaultRoute {
                                Text("默认路由").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.12)))
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                        }
                        ForEach(iface.addresses, id: \.self) { address in
                            HStack(spacing: 10) {
                                Text(address.address.description).font(.caption.monospaced())
                                Text(address.subnet.map { "/\($0.prefixLength)" } ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if !isConfigured(address.address.description, on: iface.name) {
                                    Button("添加为链路") {
                                        editing = Egress(name: "\(iface.displayName) \(address.address.description)",
                                                         interfaceName: iface.name,
                                                         localAddress: address.address.description,
                                                         kind: iface.addresses.count > 1 ? .alias : .physical)
                                        showEditor = true
                                    }
                                    .controlSize(.small)
                                } else {
                                    Text("已配置").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("在同一个 Wi-Fi 网卡上添加多个 IP 属于「多拨」实验：能否建立多个会话取决于学校是否绑定 IP 与 MAC。若登录后立刻掉线，说明被限制，请改用多个物理网口。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func isConfigured(_ address: String, on interface: String) -> Bool {
        model.config.egresses.contains { $0.localAddress == address && $0.interfaceName == interface }
    }
}

struct EgressEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var draft: Egress
    @State private var wantsAlias = false
    private let onSave: (Egress) -> Bool

    init(egress: Egress, onSave: @escaping (Egress) -> Bool) {
        _draft = State(initialValue: egress)
        self.onSave = onSave
        _wantsAlias = State(initialValue: egress.kind == .alias)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "添加链路" : "编辑链路").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()

            Form {
                Section("链路") {
                    TextField("名称", text: $draft.name, prompt: Text("例如：Wi-Fi 主链路"))
                    Picker("网卡", selection: $draft.interfaceName) {
                        ForEach(model.interfaces) { iface in
                            Text("\(iface.displayName) (\(iface.name))").tag(iface.name)
                        }
                        if !model.interfaces.contains(where: { $0.name == draft.interfaceName }) {
                            Text(draft.interfaceName).tag(draft.interfaceName)
                        }
                    }
                    HStack {
                        TextField("源 IP 地址", text: $draft.localAddress, prompt: Text("10.10.55.234"))
                        if wantsAlias {
                            Button("自动") {
                                guard let iface = model.interfaces.first(where: { $0.name == draft.interfaceName }),
                                      let subnet = iface.addresses.first?.subnet else { return }
                                var used = Set(model.config.egresses.compactMap { IPv4Address($0.localAddress) })
                                used.formUnion(iface.addresses.map(\.address))
                                if let pick = subnet.candidateAliases(count: 1, excluding: used).first {
                                    draft.localAddress = pick.description
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    Toggle("这是一个额外 IP（多拨）", isOn: $wantsAlias)
                        .onChange(of: wantsAlias) { _, newValue in
                            draft.kind = newValue ? .alias : .physical
                        }
                    Picker("绑定账号", selection: Binding(
                        get: { draft.accountID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! },
                        set: { draft.accountID = $0 == UUID(uuidString: "00000000-0000-0000-0000-000000000000")! ? nil : $0 }
                    )) {
                        Text("不绑定").tag(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
                        ForEach(model.config.accounts) { account in
                            Text(account.name.isEmpty ? account.username : account.name).tag(account.id)
                        }
                    }
                    Stepper("权重：\(draft.weight)", value: $draft.weight, in: 1...10)
                    Toggle("自动登录（失败自动重试）", isOn: $draft.autoLogin)
                    Toggle("启用", isOn: $draft.isEnabled)
                }
                if wantsAlias {
                    Section {
                        Text("保存前需要以管理员权限把 \(draft.localAddress.isEmpty ? "该地址" : draft.localAddress) 添加到 \(draft.interfaceName)。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    if wantsAlias, let iface = model.interfaces.first(where: { $0.name == draft.interfaceName }),
                       let addr = IPv4Address(draft.localAddress),
                       !iface.addresses.contains(where: { $0.address == addr }),
                       let subnet = iface.addresses.first?.subnet {
                        guard model.addAlias(on: iface, address: addr, netmask: subnet.netmask) else { return }
                    }
                    if onSave(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.isEmpty || draft.localAddress.isEmpty || draft.interfaceName.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 470, height: 560)
    }
}
