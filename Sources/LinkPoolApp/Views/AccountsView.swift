import LinkPoolCore
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Account?
    @State private var showEditor = false
    @State private var pendingDelete: Account?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.config.accounts.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.config.accounts) { account in
                            accountRow(account)
                        }
                    }
                }
                securityNote
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("账号")
        .sheet(isPresented: $showEditor) {
            if let editing {
                AccountEditorView(account: editing) { saved, password in
                    model.saveAccount(saved, password: password)
                }
            }
        }
        .confirmationDialog("删除账号？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { account in
            Button("删除 \(account.name)", role: .destructive) {
                model.deleteAccount(account)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { account in
            Text("绑定到此账号的链路会被解绑，密码会从钥匙串删除。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(text: "校园网账号", subtitle: "密码保存在系统钥匙串，不写入配置文件")
            Spacer()
            Button {
                editing = Account(name: "", username: "")
                showEditor = true
            } label: {
                Label("添加账号", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private func accountRow(_ account: Account) -> some View {
        Card(padding: 15) {
            HStack(spacing: 12) {
                IconBubble(systemName: "person.fill", tint: account.isEnabled ? Theme.accent : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.name.isEmpty ? account.username : account.name)
                            .font(.callout.weight(.semibold))
                        if !account.isEnabled {
                            Text("已停用").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(account.username).font(.caption).foregroundStyle(.secondary).monospaced()
                    HStack(spacing: 8) {
                        Label(account.portalURL.absoluteString, systemImage: "globe")
                        Text("·")
                        Text("\(boundCount(account)) 条链路")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Menu {
                    Button("编辑") { editing = account; showEditor = true }
                    Button(account.isEnabled ? "停用" : "启用") {
                        var copy = account
                        copy.isEnabled.toggle()
                        model.saveAccount(copy, password: nil)
                    }
                    Divider()
                    Button("删除", role: .destructive) { pendingDelete = account }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 12) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("还没有账号").font(.headline)
                Text("添加第一个校园网账号。只有你主动点击登录时才会使用它。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("添加账号") {
                    editing = Account(name: "", username: "")
                    showEditor = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            Text("LinkPool 只读取 /cgi-bin/rad_user_info 判断在线状态；不会自动注销任何会话。自动登录默认关闭，需要逐条链路手动开启。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func boundCount(_ account: Account) -> Int {
        model.config.egresses.filter { $0.accountID == account.id }.count
    }
}

struct AccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Account
    @State private var password: String = ""
    @State private var showPassword = false
    private let isNew: Bool
    private let onSave: (Account, String?) -> Void

    init(account: Account, onSave: @escaping (Account, String?) -> Void) {
        _draft = State(initialValue: account)
        self.isNew = account.name.isEmpty && account.username.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "添加账号" : "编辑账号").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(18)

            Divider()

            Form {
                Section("账号信息") {
                    TextField("显示名称", text: $draft.name, prompt: Text("例如：主账号"))
                    TextField("用户名", text: $draft.username, prompt: Text("学号 / 工号"))
                    HStack {
                        if showPassword {
                            TextField("密码", text: $password, prompt: Text(isNew ? "校园网密码" : "留空表示不修改"))
                        } else {
                            SecureField("密码", text: $password, prompt: Text(isNew ? "校园网密码" : "留空表示不修改"))
                        }
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("门户地址", text: Binding(
                        get: { draft.portalURL.absoluteString },
                        set: { if let url = URL(string: $0) { draft.portalURL = url } }
                    ), prompt: Text("http://4.3.2.1"))
                    if !portalURLValid {
                        Text("门户地址需要以 http:// 开头并包含主机名")
                            .font(.caption).foregroundStyle(.red)
                    }
                    TextField("ac_id（可选）", text: Binding(
                        get: { draft.acID ?? "" },
                        set: { draft.acID = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("留空自动发现"))
                    Toggle("启用此账号", isOn: $draft.isEnabled)
                }
                Section("备注") {
                    TextField("备注", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Text(isNew ? "保存后会写入钥匙串" : "留空密码表示保持原密码")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(draft, password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.username.trimmingCharacters(in: .whitespaces).isEmpty
                          || (isNew && password.isEmpty)
                          || !portalURLValid)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
        .onAppear {
            if !isNew {
                password = ""
            }
        }
    }

    private var portalURLValid: Bool {
        guard let scheme = draft.portalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = draft.portalURL.host, !host.isEmpty else { return false }
        return true
    }
}
