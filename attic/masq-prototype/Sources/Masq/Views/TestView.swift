import SwiftUI

/// เครื่องมือยิง query จริง — แยกให้เห็นว่า dnsmasq ตอบไหม กับระบบส่งมาถึง dnsmasq ไหม
/// เพราะสองอย่างนี้พังคนละสาเหตุและแก้คนละวิธี
struct TestView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var result: DNSProbe.Result?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("ชื่อโฮสต์ที่จะทดสอบ", text: $query, prompt: Text("www.myapp.test"))
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .onSubmit(run)
                    Button("ทดสอบ", action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                }

                if testing { ProgressView().controlSize(.small) }

                if let result {
                    VStack(alignment: .leading, spacing: 10) {
                        ResultLine(ok: result.viaDnsmasq,
                                   title: "ถาม dnsmasq ตรง ๆ (@127.0.0.1)",
                                   okText: "ตอบ: \(result.answers.joined(separator: ", "))",
                                   failText: "ไม่ตอบ — กฎยังไม่ถูกโหลด หรือไม่มีกฎที่ตรงกับชื่อนี้")
                        ResultLine(ok: result.viaSystem,
                                   title: "ถามผ่าน resolver ของระบบ",
                                   okText: "ระบบส่ง query มาที่ dnsmasq เรียบร้อย",
                                   failText: "ระบบไม่ได้ส่งมาที่ dnsmasq — มักเพราะขาด /etc/resolver/<tld> หรือแคชเก่ายังค้าง")

                        if result.viaDnsmasq && !result.viaSystem {
                            HStack {
                                Text("แก้ด่วน:").foregroundStyle(.secondary)
                                Button("สร้าง resolver ที่ขาด") {
                                    Task { await model.createResolvers(model.missingResolverTLDs); run() }
                                }
                                .disabled(model.missingResolverTLDs.isEmpty)
                                Button("ล้างแคช") { Task { await model.flushCache(); run() } }
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }

                if !model.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ทดสอบเร็วจากโซนที่มี").font(.headline)
                        ForEach(model.entries) { entry in
                            HStack {
                                Text(entry.primaryDomain).monospaced()
                                Spacer()
                                ProbeBadge(probe: model.probes[entry.primaryDomain])
                                Button("ลอง www.\(entry.primaryDomain)") {
                                    query = "www.\(entry.primaryDomain)"
                                    run()
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 12)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func run() {
        let host = query.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        testing = true
        Task {
            result = await model.probe(host)
            testing = false
        }
    }
}

struct ResultLine: View {
    let ok: Bool
    let title: String
    let okText: String
    let failText: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(ok ? okText : failText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
