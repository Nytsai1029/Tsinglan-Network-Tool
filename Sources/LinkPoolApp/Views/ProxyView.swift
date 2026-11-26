import LinkPoolCore
import SwiftUI
import AppKit

struct ProxyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                stats
                settingsCard
                distribution
                usage
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("代理")
    }

    private var isRunning: Bool {
        if case .running = model.proxyState { return true }
        return false
    }

    private var hero: some View {
        Card(padding: 20) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(isRunning ? Color.green.opacity(0.14) : Theme.accent.opacity(0.10))
                        .frame(width: 56, height: 56)
                    Image(systemName: isRunning ? "bolt.horizontal.circle.fill" : "network")
                        .font(.system(size: 26))
                        .foregroundStyle(isRunning ? .green : Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isRunning ? "代理运行中" : "代理未启动")
                        .font(.title3.weight(.semibold))
                    Text(isRunning
                         ? "所有连接按策略自动分配到在线链路"
                         : "启动后应用可通过本地代理同时使用多个账号")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(model.proxyAddress).font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.proxyAddress, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                Spacer()
                Button {
                    model.toggleProxy()
                } label: {
                    Text(isRunning ? "停止" : "启动")
                        .frame(width: 74)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : Theme.accent)
                .controlSize(.large)
            }
        }
    }

    private var stats: some View {
        let totals = model.proxy.metrics.grandTotals()
        return HStack(spacing: 14) {
            Card { StatTile(title: "总下行", value: Formatters.bytes(totals.bytesIn), icon: "arrow.down", tint: Theme.accent) }
            Card { StatTile(title: "总上行", value: Formatters.bytes(totals.bytesOut), icon: "arrow.up", tint: Theme.teal) }
            Card { StatTile(title: "当前连接", value: "\(totals.activeConnections)", icon: "link") }
            Card { StatTile(title: "在线链路", value: "\(model.onlineCount)", subtitle: "共 \(model.enabledEgressCount) 条", icon: "point.3.connected.trianglepath.dotted") }
        }
    }

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "分流策略", subtitle: "逐连接选择出口；同一目标站点可临时粘滞")
                Picker("", selection: $model.config.proxy.strategy) {
                    ForEach(ProxyStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.config.proxy.strategy) { _, _ in model.persist() }

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("粘滞时间 \(model.config.proxy.stickySeconds) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { Double(model.config.proxy.stickySeconds) },
                            set: { model.config.proxy.stickySeconds = Int($0) }
                        ), in: 0...300, step: 15)
                        .frame(width: 260)
                        .onChange(of: model.config.proxy.stickySeconds) { _, _ in model.persist() }
                        Text("0 秒表示每个连接独立选路，最适合加速下载")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("允许未验证链路", isOn: Binding(
                            get: { model.config.proxy.allowUnverifiedEgress },
                            set: { model.config.proxy.allowUnverifiedEgress = $0; model.persist() }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Text("门户接口不可达时仍经链路转发，仅用于单链路排障")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("监听端口").font(.caption).foregroundStyle(.secondary)
                        TextField("", value: $model.config.proxy.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onChange(of: model.config.proxy.port) { _, _ in model.persist() }
                        Text("修改后需重启代理").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var distribution: some View {
        let totals = model.proxy.metrics.allTotals()
        let maxBytes = max(1, totals.values.map(\.bytesIn).max() ?? 1)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "流量分布", subtitle: "每个出口各自的累计下行")
                if model.config.egresses.isEmpty {
                    Text("尚未配置链路").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.config.egresses) { egress in
                        let bytes = totals[egress.id]?.bytesIn ?? 0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(egress.name).font(.caption)
                                Spacer()
                                Text(Formatters.bytes(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.06))
                                    Capsule().fill(Theme.heroGradient)
                                        .frame(width: max(3, geo.size.width * CGFloat(Double(bytes) / Double(maxBytes))))
                                }
                            }
                            .frame(height: 7)
                        }
                    }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var usage: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "如何让应用使用代理", subtitle: "LinkPool 不修改系统全局代理，避免影响其他调试")
                HStack(alignment: .top, spacing: 10) {
                    Text("SOCKS5").font(.caption.weight(.semibold)).frame(width: 62, alignment: .leading)
                    Text("\(model.proxyAddress)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("HTTP").font(.caption.weight(.semibold)).frame(width: 62, alignment: .leading)
                    Text("http://\(model.proxyAddress)（支持 CONNECT 与绝对 URI）")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("单连接测速").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制") {
                            copy("curl -x http://\(model.proxyAddress) https://speed.cloudflare.com/__down?bytes=100000000")
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                    Text("curl -x http://\(model.proxyAddress) https://speed.cloudflare.com/__down?bytes=100000000")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("多连接加速下载（aria2）").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制") {
                            copy("aria2c -x16 -s16 -k1M --all-proxy=socks5h://\(model.proxyAddress) \"URL\"")
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                    Text("aria2c -x16 -s16 -k1M --all-proxy=socks5h://\(model.proxyAddress) \"URL\"")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
