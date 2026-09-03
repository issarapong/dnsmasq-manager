import SwiftUI

struct ZoneEditor: View {
    enum Target: Identifiable {
        case new
        case existing(ZoneEntry)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let e): e.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: Target

    @State private var kind: ZoneEntry.Kind = .address
    @State private var domainText = ""
    @State private var targetText = "127.0.0.1"
    @State private var linkResolver = true
    @State private var restart = true
    @State private var loaded = false

    private var isNew: Bool { if case .new = target { true } else { false } }

    private var domains: [String] {
        domainText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var tlds: [String] {
        Array(Set(domains.compactMap { $0.split(separator: ".").last.map(String.init) })).sorted()
    }

    private var missingTLDs: [String] {
        let have = Set(model.resolverEntries.filter(\.pointsToLoopback).map(\.tld))
        return tlds.filter { !have.contains($0) }
    }

    private var validationError: String? {
        guard !domains.isEmpty else { return "ใส่ชื่อโดเมนก่อน" }
        if let bad = domains.first(where: { !$0.contains(".") }) {
            return "“\(bad)” ไม่มีจุด — ควรเป็นแบบ myapp.test"
        }
        if let bad = domains.first(where: { $0.hasPrefix(".") || $0.hasSuffix(".") }) {
            return "“\(bad)” ขึ้นหรือลงท้ายด้วยจุด"
        }
        let t = targetText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "ใส่ปลายทางก่อน" }
        if kind == .address && t.contains("#") { return "address= ใส่พอร์ตไม่ได้ ใช้ server= แทน" }
        if isNew && domains.count > 1 { return "เพิ่มทีละโดเมน (แก้เป็นหลายโดเมนได้ทีหลัง)" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "เพิ่มโซนใหม่" : "แก้ไขโซน")
                .font(.title2.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Form {
                Picker("ชนิด", selection: $kind) {
                    ForEach(ZoneEntry.Kind.allCases, id: \.self) { k in
                        Text(k.label).tag(k)
                    }
                }
                .pickerStyle(.radioGroup)

                TextField("โดเมน", text: $domainText, prompt: Text("myapp.test"))
                    .textFieldStyle(.roundedBorder)

                TextField(kind == .address ? "ตอบเป็น IP" : "ส่งต่อไปที่",
                          text: $targetText,
                          prompt: Text(kind == .address ? "127.0.0.1" : "10.0.0.1#5353"))
                    .textFieldStyle(.roundedBorder)
                    .monospaced()

                if kind == .address, let first = domains.first {
                    LabeledContent("จะครอบถึง") {
                        Text("\(first), www.\(first), api.\(first) และ subdomain ทุกชั้น")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !missingTLDs.isEmpty {
                    Toggle(isOn: $linkResolver) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("สร้าง " + missingTLDs.map { "/etc/resolver/\($0)" }.joined(separator: ", "))
                            Text("ถ้าไม่สร้าง macOS จะไม่ส่ง query มาที่ dnsmasq เลย")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("รีสตาร์ท dnsmasq และล้างแคชหลังบันทึก", isOn: $restart)

                if isNew, let store = zoneStore {
                    LabeledContent("จะเขียนลงไฟล์") {
                        Text(store).monospaced().font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let err = validationError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("ยกเลิก") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "เพิ่ม" : "บันทึก") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationError != nil)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear(perform: loadIfNeeded)
    }

    private var zoneStore: String? {
        guard let paths = model.paths, let first = domains.first else { return nil }
        return ZoneStore(paths: paths).suggestedFileName(for: first)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if case .existing(let e) = target {
            kind = e.kind
            domainText = e.domains.joined(separator: ", ")
            targetText = e.target
        }
    }

    private func save() {
        let t = targetText.trimmingCharacters(in: .whitespaces)
        Task {
            switch target {
            case .new:
                await model.createZone(kind: kind, domain: domains[0], target: t,
                                       linkResolver: linkResolver, restart: restart)
            case .existing(let e):
                await model.updateZone(e, kind: kind, domains: domains, target: t, restart: restart)
                if linkResolver && !missingTLDs.isEmpty {
                    await model.createResolvers(missingTLDs)
                }
                await model.probeAll()
            }
            dismiss()
        }
    }
}
