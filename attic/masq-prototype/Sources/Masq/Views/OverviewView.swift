import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let err = model.setupError {
                    DiagnosticRow(diagnostic: Diagnostic(severity: .error, title: "ตั้งค่าไม่ครบ",
                                                         detail: err, fixLabel: nil, fix: nil))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("สุขภาพระบบ").font(.title3.bold())
                    ForEach(model.diagnostics) { d in DiagnosticRow(diagnostic: d) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("โซนที่ประกาศไว้").font(.title3.bold())
                    if model.entries.isEmpty {
                        Text("ยังไม่มีโซน — ไปที่แท็บ “โซน” แล้วกดเพิ่ม")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries) { entry in
                            ZoneSummaryRow(entry: entry, probe: model.probes[entry.primaryDomain])
                        }
                    }
                }

                if let paths = model.paths {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ที่อยู่ไฟล์").font(.title3.bold())
                        PathRow(label: "คอนฟิกหลัก", url: paths.mainConf)
                        PathRow(label: "โฟลเดอร์โซน", url: paths.confDir)
                        PathRow(label: "Resolver", url: Paths.resolverDir)
                        PathRow(label: "launchd", url: Paths.launchdPlist)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DiagnosticRow: View {
    @Environment(AppModel.self) private var model
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title).fontWeight(.medium)
                if !diagnostic.detail.isEmpty {
                    Text(diagnostic.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let label = diagnostic.fixLabel, let fix = diagnostic.fix {
                Button(label) { Task { try? await fix() } }
            }
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch diagnostic.severity {
        case .error: .red
        case .warning: .orange
        case .ok: .green
        }
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }
}

struct ZoneSummaryRow: View {
    let entry: ZoneEntry
    let probe: DNSProbe.Result?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .address ? "arrow.down.right.circle" : "arrow.turn.up.right")
                .foregroundStyle(.secondary)
            Text(entry.displayDomains).fontWeight(.medium)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Text(entry.target).monospaced()
            Spacer()
            ProbeBadge(probe: probe)
            Text(entry.file.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ProbeBadge: View {
    let probe: DNSProbe.Result?

    var body: some View {
        if probe != nil {
            Text(text)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
                .help(help)
        }
    }

    private var text: String {
        guard let probe else { return "" }
        if probe.isHealthy { return "ใช้งานได้" }
        if probe.viaDnsmasq { return "ระบบยังไม่ route" }
        return "ไม่ตอบ"
    }

    private var help: String {
        guard let probe else { return "" }
        return "dnsmasq: \(probe.viaDnsmasq ? "ตอบ" : "ไม่ตอบ") · ระบบ: \(probe.viaSystem ? "ตอบ" : "ไม่ตอบ")"
    }

    private var color: Color {
        guard let probe else { return .secondary }
        if probe.isHealthy { return .green }
        return probe.viaDnsmasq ? .orange : .red
    }
}

struct PathRow: View {
    let label: String
    let url: URL

    var body: some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading).foregroundStyle(.secondary)
            Text(url.path).monospaced().font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("เปิดใน Finder")
        }
        .font(.callout)
    }
}
