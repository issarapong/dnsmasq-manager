import Foundation

struct ServiceStatus: Equatable {
    enum State: Equatable {
        case running(pid: Int32)
        case loadedNotRunning
        case notLoaded
        case unknown(String)

        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    var state: State = .unknown("ยังไม่ได้ตรวจ")
    var version: String?
    var listeningOn53: Bool = false
    var configOK: Bool?
    var configError: String?

    var summary: String {
        switch state {
        case .running(let pid):   "กำลังทำงาน (pid \(pid))"
        case .loadedNotRunning:   "โหลดไว้แต่ไม่ทำงาน"
        case .notLoaded:          "ไม่ได้โหลด"
        case .unknown(let why):   why
        }
    }
}

/// ผลตรวจสุขภาพหนึ่งข้อ พร้อมวิธีแก้ที่กดได้จริง
struct Diagnostic: Identifiable {
    enum Severity { case error, warning, ok }

    let id = UUID()
    var severity: Severity
    var title: String
    var detail: String
    /// ข้อความบนปุ่มแก้ไข ถ้าแก้อัตโนมัติได้
    var fixLabel: String?
    var fix: (@Sendable () async throws -> Void)?
}
