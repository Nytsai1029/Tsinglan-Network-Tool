import LinkPoolCore
import SwiftUI
import AppKit

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var minimum: LogLevel = .info
    @State private var query = ""
    @State private var follow = true

    private var filtered: [LogEntry] {
        model.logs.filter { entry in
            entry.level >= minimum &&
            (query.isEmpty
             || entry.message.localizedCaseInsensitiveContains(query)
             || entry.category.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: filtered.count) { _, _ in
                    guard follow, let last = filtered.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("日志")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $minimum) {
                Text("全部").tag(LogLevel.debug)
                Text("信息").tag(LogLevel.info)
                Text("警告").tag(LogLevel.warn)
                Text("错误").tag(LogLevel.error)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            TextField("搜索", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Toggle("自动滚动", isOn: $follow).toggleStyle(.checkbox)

            Spacer()

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logDirectory)
            } label: {
                Label("日志目录", systemImage: "folder")
            }
            Button(role: .destructive) {
                Log.shared.clear()
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Formatters.time(entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Text(entry.level.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color(entry.level))
                .frame(width: 40, alignment: .leading)
            Text(entry.category)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 3)
        .background(entry.level >= .warn ? color(entry.level).opacity(0.05) : .clear)
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return Theme.accent
        case .warn: return .orange
        case .error: return .red
        }
    }

    private var logDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
    }
}
