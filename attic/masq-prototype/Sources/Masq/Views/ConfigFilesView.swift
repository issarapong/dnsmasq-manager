import SwiftUI

struct ConfigFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ConfFile.ID?
    @State private var draft = ""
    @State private var loadedID: ConfFile.ID?
    @State private var restartOnSave = true

    private var current: ConfFile? {
        model.files.first { $0.id == selected } ?? model.files.first
    }

    private var isDirty: Bool {
        guard let current else { return false }
        return draft != current.lines.joined(separator: "\n")
    }

    var body: some View {
        HSplitView {
            List(model.files, selection: $selected) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).fontWeight(file.id == current?.id ? .semibold : .regular)
                    Text("\(file.entries.count) กฎ").font(.caption).foregroundStyle(.secondary)
                }
                .tag(file.id)
            }
            .frame(minWidth: 190, idealWidth: 210, maxWidth: 280)

            VStack(spacing: 0) {
                if let current {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)

                    Divider()
                    HStack {
                        Text(current.url.path).font(.caption).monospaced()
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Toggle("รีสตาร์ทหลังบันทึก", isOn: $restartOnSave)
                            .toggleStyle(.checkbox)
                        Button("คืนค่า") { load(current, force: true) }
                            .disabled(!isDirty)
                        Button("บันทึก") {
                            Task {
                                await model.saveRawConfig(draft, to: current.url, restart: restartOnSave)
                                await model.probeAll()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                        .help("ตรวจ syntax ก่อนเขียนทับไฟล์จริงเสมอ")
                    }
                    .padding(10)
                } else {
                    ContentUnavailableView("ไม่มีไฟล์คอนฟิก", systemImage: "doc.plaintext")
                }
            }
            .frame(minWidth: 420)
        }
        .onAppear { if let c = current { load(c) } }
        .onChange(of: selected) { _, _ in if let c = current { load(c) } }
        .onChange(of: model.files) { _, _ in
            // ไฟล์ถูกเขียนใหม่จากที่อื่น — อัปเดต editor เฉพาะตอนที่ยังไม่มีการแก้ค้างไว้
            if let c = current, !isDirty { load(c, force: true) }
        }
    }

    private func load(_ file: ConfFile, force: Bool = false) {
        guard force || loadedID != file.id else { return }
        draft = file.lines.joined(separator: "\n")
        loadedID = file.id
        selected = file.id
    }
}
