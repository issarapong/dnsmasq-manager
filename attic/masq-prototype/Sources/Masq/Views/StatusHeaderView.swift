import SwiftUI

struct StatusHeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(dotColor.opacity(0.35), lineWidth: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.summary).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if model.status.state.isRunning {
                Button("รีสตาร์ท") { Task { await model.restartAndFlush() } }
                Button("หยุด") { Task { await model.perform(.stop) } }
            } else {
                Button("เริ่ม") { Task { await model.perform(.start) } }
                    .buttonStyle(.borderedProminent)
            }
            Button("ล้างแคช") { Task { await model.flushCache() } }
            Button {
                Task { await model.refresh(); await model.probeAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("รีเฟรชสถานะและทดสอบทุกโซนใหม่")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var dotColor: Color {
        guard model.status.state.isRunning else { return .red }
        return model.diagnostics.contains { $0.severity == .error } ? .orange : .green
    }

    private var subtitle: String {
        var bits: [String] = []
        if let v = model.status.version { bits.append("dnsmasq \(v)") }
        if let p = model.paths { bits.append(p.prefix.path) }
        bits.append(model.status.listeningOn53 ? "ฟัง UDP/53" : "ไม่พบพอร์ต 53")
        bits.append("\(model.entries.count) โซน")
        return bits.joined(separator: " · ")
    }
}
