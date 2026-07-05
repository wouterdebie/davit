import SwiftUI

/// Switches the app between a regular app (Dock icon, ⌘Tab) while a window is
/// open and a menu-bar-only accessory when the last window closes — the
/// standard behavior for menu-bar utilities (unless the user opts out).
@MainActor
final class DockVisibility {
    static let shared = DockVisibility()
    private var observers: [NSObjectProtocol] = []

    var keepInDock: Bool {
        UserDefaults.standard.bool(forKey: "keepInDock")
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            let closing = note.object as? NSWindow
            Task { @MainActor in
                guard !DockVisibility.shared.keepInDock else { return }
                let remaining = NSApp.windows.filter {
                    $0 !== closing && $0.isVisible && $0.canBecomeMain
                }
                if remaining.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            Task { @MainActor in
                if window?.canBecomeMain == true, NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        })
    }
}

struct ContainerStackApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // A single reopenable window (WindowGroup windows die on close and the
        // menu bar extra could no longer reopen them).
        Window("Davit", id: "main") {
            MainWindow()
                .environmentObject(state)
                .frame(minWidth: 940, minHeight: 560)
                .task {
                    DockVisibility.shared.start()
                    state.startPolling()
                }
        }
        .defaultSize(width: 1180, height: 720)
        // Always present the window on launch: without this, state restoration
        // remembers a closed window and the app launches windowless (which also
        // hangs headless --snapshot/--probe runs waiting for MainWindow).
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await state.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            MenuBarIcon()
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// The menu bar icon exists from launch even when no window does, so it also
/// hosts the harness fallback: headless launches of the bundled app sometimes
/// never materialize the Window scene — if no window appears, open it.
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "shippingbox.fill")
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard args.contains(where: { $0.hasPrefix("--snapshot") || $0.hasPrefix("--probe") }) else { return }
                try? await Task.sleep(for: .seconds(2))
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    FileHandle.standardError.write(Data("harness: window missing after launch, forcing open\n".utf8))
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

// MARK: - Menu bar extra

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch state.systemState {
            case .running:
                Label("Services running", systemImage: "circle.fill")
                Button("Stop Services") { state.toggleSystem() }
            case .stopped:
                Label("Services stopped", systemImage: "circle")
                Button("Start Services") { state.toggleSystem() }
            case .unknown:
                Label("Status unknown", systemImage: "questionmark.circle")
            }

            Divider()

            if state.runningContainers.isEmpty {
                Text("No running containers")
            } else {
                Text("Running Containers")
                ForEach(state.runningContainers) { c in
                    Menu(c.id) {
                        Button("Stop") { state.stopContainer(c) }
                        Button("Restart") { state.restartContainer(c) }
                        Button("Open Terminal") { TerminalLauncher.openShell(containerID: c.id) }
                    }
                }
            }

            Divider()

            if let update = state.availableUpdate {
                Button("Update to Davit \(update.version)…") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Divider()
            }
            Button("Open Davit") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Davit") { NSApp.terminate(nil) }
        }
    }
}
