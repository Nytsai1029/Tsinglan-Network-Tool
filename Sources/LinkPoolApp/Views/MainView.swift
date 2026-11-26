import LinkPoolCore
import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.heroGradient)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("LinkPool").font(.system(size: 15, weight: .semibold))
                    Text("多账号校园网聚合").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
                    .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.5)
            proxyFooter
        }
        .background(.ultraThinMaterial)
    }

    private var proxyFooter: some View {
        HStack(spacing: 10) {
            PhaseDot(phase: proxyPhase)
            VStack(alignment: .leading, spacing: 1) {
                Text(proxyStateText).font(.caption.weight(.medium))
                Text(model.proxyAddress).font(.caption2).foregroundStyle(.secondary).monospaced()
            }
            Spacer()
            Button {
                model.toggleProxy()
            } label: {
                Image(systemName: isProxyRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(isProxyRunning ? .red : Theme.accent)
            }
            .buttonStyle(.plain)
            .help(isProxyRunning ? "停止代理" : "启动代理")
        }
        .padding(14)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: OverviewView()
        case .accounts: AccountsView()
        case .egresses: EgressesView()
        case .proxy: ProxyView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }

    private var isProxyRunning: Bool {
        if case .running = model.proxyState { return true }
        return false
    }

    private var proxyPhase: SessionPhase {
        switch model.proxyState {
        case .running: return .online
        case .failed: return .failed
        case .stopped: return .offline
        }
    }

    private var proxyStateText: String {
        switch model.proxyState {
        case .running: return "代理运行中"
        case .failed(let message): return message
        case .stopped: return "代理未启动"
        }
    }
}
