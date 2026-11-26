import LinkPoolCore
import SwiftUI
import AppKit

@main
struct LinkPoolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(model.menuBarText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private var symbol: String {
        if case .running = model.proxyState { return "arrow.left.arrow.right.circle.fill" }
        return "circle.dashed"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.info("app", "launch args=\(CommandLine.arguments)")
        let background = CommandLine.arguments.contains("--background")
            || ProcessInfo.processInfo.environment["LINKPOOL_BACKGROUND"] == "1"
        if background {
            NSApp.setActivationPolicy(.accessory)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.showMainWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingView(rootView: MainView().environmentObject(AppModel.shared))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "LinkPool"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentView = hosting
            window.minSize = NSSize(width: 900, height: 620)
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
