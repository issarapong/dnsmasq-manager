import Foundation

enum PrivilegedError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:        "ยกเลิกการยืนยันรหัสผ่าน"
        case .failed(let msg):  msg
        }
    }
}

enum Privileged {
    /// รันสคริปต์ในสิทธิ์ admin ผ่าน osascript
    ///
    /// ทุก action ควรรวมทุกคำสั่งเป็นสคริปต์เดียวก่อนเรียก เพื่อให้ผู้ใช้
    /// ถูกถามรหัสผ่านครั้งเดียว ไม่ใช่ครั้งละคำสั่ง
    @discardableResult
    static func run(_ script: String) throws -> String {
        // สคริปต์ต้องผ่านสองชั้น: AppleScript string แล้วค่อยเป็น shell
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let result = Shell.run("/usr/bin/osascript",
                               ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
                               timeout: 120)
        if result.ok { return result.stdout }

        let err = result.output
        if err.contains("-128") || err.localizedCaseInsensitiveContains("User canceled") {
            throw PrivilegedError.cancelled
        }
        throw PrivilegedError.failed(err.isEmpty ? "คำสั่งล้มเหลว (status \(result.status))" : err)
    }

    /// ห่อ path ให้ปลอดภัยเวลาเอาไปต่อเป็นสคริปต์ shell
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
