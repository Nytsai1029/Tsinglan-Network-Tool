import LinkPoolCore
import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if model.config.accounts.isEmpty || model.config.egresses.isEmpty {
                    gettingStarted
                }
                chartCard
                egressSection
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .navigationTitle("概览")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.checkAll()
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isProxyRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(isProxyRunning ? "聚合代理运行中" : "聚合代理未启动")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(Formatters.speed(model.totalDown))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("当前总下载速度 · 上传 \(Formatters.speed(model.totalUp))")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 10) {
                    Button {
                        model.toggleProxy()
                    } label: {
                        Label(isProxyRunning ? "停止代理" : "启动代理",
                              systemImage: isProxyRunning ? "stop.fill" : "play.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(.white))
                            .foregroundStyle(Color(red: 0.07, green: 0.22, blue: 0.42))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 14) {
                heroStat("在线链路", "\(model.onlineCount) / \(model.enabledEgressCount)")
                heroStat("活跃连接", "\(model.proxy.metrics.activeConnections)")
                heroStat("代理端口", "\(model.config.proxy.port)")
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.heroGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            RadialGradient(colors: [.white.opacity(0.16), .clear],
                                           center: .topTrailing,
                                           startRadius: 10, endRadius: 420)
                        )
                )
        )
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 160, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.06))
                .offset(x: 20, y: 30)
                .clipped()
        }
    }

    private func heroStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "吞吐趋势", subtitle: "最近 2 分钟 · 所有链路合计")
                    Spacer()
                    LegendDot(color: Theme.accent, label: "下载")
                    LegendDot(color: Theme.teal, label: "上传")
                }
                if model.history.count < 2 {
                    placeholderChart
                } else {
                    Chart(model.history) { point in
                        AreaMark(x: .value("时间", point.date),
                                 y: .value("下载", point.down))
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("时间", point.date),
                                 y: .value("下载", point.down))
                            .foregroundStyle(Theme.accent)
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("时间", point.date),
                                 y: .value("上传", point.up))
                            .foregroundStyle(Theme.teal)
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(Formatters.speed(number))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 150)
                }
            }
        }
    }

    private var placeholderChart: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.03))
            .frame(height: 150)
            .overlay(
                Text("启动代理并产生流量后，这里会显示实时曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
    }

    // MARK: - Egresses

    private var egressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(text: "链路", subtitle: "每个 IP 对应一个校园网会话")
                Spacer()
                Button("管理") { model.selection = .egresses }
                    .buttonStyle(.link)
            }
            if model.config.egresses.isEmpty {
                Card {
                    Text("还没有链路。先在「账号」中添加账号，再在「链路」中绑定网卡。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 265), spacing: 12)], spacing: 12) {
                    ForEach(model.config.egresses) { egress in
                        EgressCard(egress: egress)
                    }
                }
            }
        }
    }

    // MARK: - Getting started

    private var gettingStarted: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("三步开始").font(.headline)
                StepRow(index: 1, title: "添加账号", detail: "在「账号」里保存校园网用户名与密码（存入系统钥匙串）。")
                StepRow(index: 2, title: "绑定链路", detail: "在「链路」里选择网卡与地址，并绑定刚添加的账号。")
                StepRow(index: 3, title: "启动代理", detail: "点击「启动代理」，把浏览器或下载器的代理设为 \(model.proxyAddress)。")
            }
        }
    }

    private var isProxyRunning: Bool {
        if case .running = model.proxyState { return true }
        return false
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct StepRow: View {
    let index: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct EgressCard: View {
    @EnvironmentObject private var model: AppModel
    let egress: Egress

    var body: some View {
        Card(padding: 15) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PhaseDot(phase: snapshot.phase)
                    Text(egress.name).font(.callout.weight(.semibold))
                    Spacer()
                    PhaseBadge(phase: snapshot.phase)
                }
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.caption2)
                    Text(egress.localAddress).font(.caption).monospaced()
                    Text("·").foregroundStyle(.tertiary)
                    Text(egress.interfaceName).font(.caption)
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(Formatters.speed(model.speed(for: egress).down), systemImage: "arrow.down")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                    Label(Formatters.speed(model.speed(for: egress).up), systemImage: "arrow.up")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.teal)
                    Spacer()
                    Text(model.account(id: egress.accountID)?.name ?? "未绑定")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        model.login(egress: egress)
                    } label: {
                        Label("登录", systemImage: "person.badge.key")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    if snapshot.phase == .online {
                        Button(role: .destructive) {
                            model.logout(egress: egress)
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        .controlSize(.small)
                        .help("注销此链路（不会影响其他链路）")
                    }
                }
            }
        }
    }

    private var snapshot: SessionManager.EgressRuntime { model.snapshot(for: egress) }
}
