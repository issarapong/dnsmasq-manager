import SwiftUI

struct ZonesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ZoneEditor.Target?
    @State private var confirmDelete: ZoneEntry?

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label("ยังไม่มีโซน", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("เพิ่มโซนเพื่อชี้โดเมนสำหรับ dev มาที่เครื่องนี้\nเช่น `myapp.test` → `127.0.0.1`")
                } actions: {
                    Button("เพิ่มโซน") { editing = .new }.buttonStyle(.borderedProminent)
                }
            } else {
                Table(model.entries) {
                    TableColumn("โดเมน") { e in
                        HStack(spacing: 6) {
                            Text(e.displayDomains).fontWeight(.medium)
                            if !e.isSimple {
                                Text("หลายโดเมน").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    TableColumn("ชนิด") { e in Text(e.kind.short).monospaced().foregroundStyle(.secondary) }
                        .width(70)
                    TableColumn("ปลายทาง") { e in Text(e.target).monospaced() }.width(140)
                    TableColumn("Resolver") { e in ResolverStatusCell(entry: e) }.width(110)
                    TableColumn("สถานะ") { e in ProbeBadge(probe: model.probes[e.primaryDomain]) }.width(120)
                    TableColumn("ไฟล์") { e in
                        Text(e.file.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                    }
                    TableColumn("") { e in
                        HStack(spacing: 4) {
                            Button("แก้ไข") { editing = .existing(e) }
                            Button(role: .destructive) { confirmDelete = e } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(90)
                }
            }

            Divider()
            HStack {
                Button {
                    editing = .new
                } label: {
                    Label("เพิ่มโซน", systemImage: "plus")
                }
                Button("ทดสอบทุกโซนใหม่") { Task { await model.probeAll() } }
                Spacer()
                if let t = model.lastRefresh {
                    Text("อัปเดตล่าสุด \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .sheet(item: $editing) { target in
            ZoneEditor(target: target).environment(model)
        }
        .confirmationDialog("ลบโซนนี้?", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { entry in
            Button("ลบ \(entry.displayDomains)", role: .destructive) {
                Task { await model.deleteZone(entry, restart: true); await model.probeAll() }
                confirmDelete = nil
            }
            Button("ยกเลิก", role: .cancel) { confirmDelete = nil }
        } message: { entry in
            Text("ลบบรรทัดออกจาก \(entry.file.lastPathComponent) แล้วรีสตาร์ท dnsmasq\nถ้าไฟล์ไม่เหลือกฎอื่น ไฟล์จะถูกลบไปด้วย")
        }
    }
}

struct ResolverStatusCell: View {
    @Environment(AppModel.self) private var model
    let entry: ZoneEntry

    private var missing: [String] {
        let have = Set(model.resolverEntries.filter(\.pointsToLoopback).map(\.tld))
        return entry.requiredResolvers.subtracting(have).sorted()
    }

    var body: some View {
        if missing.isEmpty {
            Label("ครบ", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
        } else {
            Button {
                Task { await model.createResolvers(missing) }
            } label: {
                Label("ขาด — สร้าง", systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("ยังไม่มี " + missing.map { "/etc/resolver/\($0)" }.joined(separator: ", "))
        }
    }
}
