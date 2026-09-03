import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.state.isRunning ? "dnsmasq: ทำงานอยู่" : "dnsmasq: \(model.status.summary)")

        if !model.entries.isEmpty {
            Divider()
            ForEach(model.entries.prefix(8)) { entry in
                Text("\(entry.displayDomains) → \(entry.target)")
            }
        }

        Divider()
        Button("รีสตาร์ท + ล้างแคช") { Task { await model.restartAndFlush() } }
        Button(model.status.state.isRunning ? "หยุดบริการ" : "เริ่มบริการ") {
            Task { await model.perform(model.status.state.isRunning ? .stop : .start) }
        }
        Button("รีเฟรชสถานะ") { Task { await model.refresh() } }

        Divider()
        Button("เปิดหน้าต่าง Masq") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("ออก") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
