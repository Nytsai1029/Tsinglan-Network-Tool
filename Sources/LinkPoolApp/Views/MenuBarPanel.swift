import LinkPoolCore
import SwiftUI
import AppKit

struct MenuBarPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            speedRow
            Divider().opacity(0.6)
            egressList
            Divider().opacity(0.6)
            actions
        }
        .frame(width: 330)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.heroGradient)
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("LinkPool").font(.system(size: 14, weight: .semibold))
                Text(statusText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.toggleProxy()
            } label: {
                Text(isRunning ? "停止" : "启动")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(isRunning ? .red : Theme.accent)
        }
        .padding(14)
    }

    private var speedRow: some View {
        HStack(spacing: 0) {
            speedTile(title: "下载", value: Formatters.speed(model.totalDown), icon: "arrow.down")
            Divider().frame(height: 26)
            speedTile(title: "上传", value: Formatters.speed(model.totalUp), icon: "arrow.up")
            Divider().frame(height: 26)
            speedTile(title: "在线", value: "\(model.onlineCount)/\(model.enabledEgressCount)", icon: "bolt.horizontal")
        }
        .padding(.vertical, 12)
    }

    private func speedTile(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8, weight: .bold))
                Text(title).font(.caption2)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private var egressList: some View {
        VStack(spacing: 0) {
            if model.config.egresses.isEmpty {
                Text("还没有配置链路，打开面板添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(model.config.egresses.prefix(4)) { egress in
                    HStack(spacing: 9) {
                        PhaseDot(phase: model.snapshot(for: egress).phase)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(egress.name).font(.system(size: 12, weight: .medium))
                            Text("\(egress.localAddress) · \(accountName(egress))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Formatters.speed(model.speed(for: egress).down))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            model.login(egress: egress)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("立即登录")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        VStack(spacing: 2) {
            panelButton("打开控制面板", icon: "macwindow") {
                (NSApp.delegate as? AppDelegate)?.showMainWindow()
            }
            panelButton("复制代理地址", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://\(model.proxyAddress)", forType: .string)
            }
            panelButton("退出 LinkPool", icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
    }

    private func panelButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func accountName(_ egress: Egress) -> String {
        model.account(id: egress.accountID)?.name ?? "未绑定账号"
    }

    private var isRunning: Bool {
        if case .running = model.proxyState { return true }
        return false
    }

    private var statusText: String {
        if case .running = model.proxyState {
            return "\(model.onlineCount) 条链路在线 · \(model.proxyAddress)"
        }
        return "代理未启动 · \(model.proxyAddress)"
    }
}
