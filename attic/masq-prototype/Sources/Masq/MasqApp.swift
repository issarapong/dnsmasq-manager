import SwiftUI

@main
struct MasqApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Masq — dnsmasq", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    await model.refresh()
                    await model.probeAll()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("รีเฟรช") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("รีสตาร์ท dnsmasq") { Task { await model.restartAndFlush() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(systemName: "globe.badge.chevron.backward")
                .symbolVariant(model.status.state.isRunning ? .none : .slash)
        }
    }
}
