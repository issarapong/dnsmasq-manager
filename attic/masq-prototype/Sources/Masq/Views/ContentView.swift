import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview, zones, resolvers, files, test
    var id: Self { self }

    var title: String {
        switch self {
        case .overview:  "ภาพรวม"
        case .zones:     "โซน"
        case .resolvers: "Resolver"
        case .files:     "ไฟล์คอนฟิก"
        case .test:      "ทดสอบ"
        }
    }

    var icon: String {
        switch self {
        case .overview:  "gauge.with.dots.needle.33percent"
        case .zones:     "point.3.connected.trianglepath.dotted"
        case .resolvers: "arrow.triangle.branch"
        case .files:     "doc.plaintext"
        case .test:      "stethoscope"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section = .overview

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                StatusHeaderView()
                Divider()
                Group {
                    switch selection {
                    case .overview:  OverviewView()
                    case .zones:     ZonesView()
                    case .resolvers: ResolversView()
                    case .files:     ConfigFilesView()
                    case .test:      TestView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if let label = model.busyLabel { BusyOverlay(label: label) }
        }
        .alert(item: $model.alert) { payload in
            Alert(title: Text(payload.title), message: Text(payload.message), dismissButton: .default(Text("ตกลง")))
        }
        .disabled(model.isBusy)
    }

    /// ตัวเลขแดงบน sidebar ให้เห็นปัญหาโดยไม่ต้องคลิกเข้าไปดู
    private func badge(for section: Section) -> Int {
        switch section {
        case .overview:  model.diagnostics.filter { $0.severity != .ok }.count
        case .zones:     model.entries.count
        case .resolvers: model.missingResolverTLDs.count
        default:         0
        }
    }
}

struct BusyOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(spacing: 12) {
                ProgressView()
                Text(label).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}
