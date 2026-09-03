import SwiftUI

struct ResolversView: View {
    @Environment(AppModel.self) private var model
    @State private var newTLD = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ไฟล์ใน /etc/resolver บอก macOS ว่า TLD ไหนต้องถาม DNS ตัวไหน — ถ้าไม่มีไฟล์ กฎใน dnsmasq จะไม่มีผลกับเครื่องนี้เลย")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.missingResolverTLDs.isEmpty {
                        HStack {
                            Label("มีโซนที่ยังขาด resolver: " + model.missingResolverTLDs.map { ".\($0)" }.joined(separator: ", "),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Button("สร้างทั้งหมด") {
                                Task { await model.createResolvers(model.missingResolverTLDs); await model.probeAll() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if model.resolverEntries.isEmpty {
                        Text("ยังไม่มีไฟล์ resolver").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.resolverEntries) { entry in
                            ResolverRow(entry: entry)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                TextField("เพิ่ม TLD เอง", text: $newTLD, prompt: Text("test"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(add)
                Button("เพิ่ม", action: add)
                    .disabled(cleanTLD.isEmpty)
                Spacer()
            }
            .padding(12)
        }
    }

    private var cleanTLD: String {
        newTLD.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func add() {
        let tld = cleanTLD
        guard !tld.isEmpty else { return }
        newTLD = ""
        Task { await model.createResolvers([tld]) }
    }
}

struct ResolverRow: View {
    @Environment(AppModel.self) private var model
    let entry: ResolverStore.Entry

    private var isUsed: Bool {
        model.entries.contains { $0.requiredResolvers.contains(entry.tld) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.pointsToLoopback ? "arrow.triangle.branch" : "questionmark.circle")
                .foregroundStyle(entry.pointsToLoopback ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(".\(entry.tld)").fontWeight(.medium)
                Text("nameserver \(entry.nameserver ?? "—")").font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            if !isUsed {
                Text("ไม่มีโซนใช้").font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Button(role: .destructive) {
                Task { await model.removeResolver(entry.tld) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
