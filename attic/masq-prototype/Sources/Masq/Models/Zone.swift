import Foundation

/// หนึ่งบรรทัดคำสั่งใน dnsmasq ที่ประกาศโซน
///
/// dnsmasq ยอมให้ประกาศหลายโดเมนในบรรทัดเดียว (`address=/a.test/b.test/1.2.3.4`)
/// เลยเก็บเป็น `domains` ไม่ใช่ค่าเดี่ยว บรรทัดแบบนั้นแก้ผ่าน UI ปกติไม่ได้
/// ต้องไปแก้ raw config เอา
struct ZoneEntry: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case address
        case server

        var label: String {
            switch self {
            case .address: "address — ตอบ IP นี้เสมอ"
            case .server:  "server — ส่งต่อไป DNS ตัวอื่น"
            }
        }

        var short: String { rawValue }
    }

    var id: String { "\(file.path)#\(lineIndex)" }

    var kind: Kind
    var domains: [String]
    /// `127.0.0.1` สำหรับ address, หรือ `10.0.0.1#5353` สำหรับ server
    var target: String
    var file: URL
    var lineIndex: Int
    var raw: String

    var isSimple: Bool { domains.count == 1 }
    var primaryDomain: String { domains.first ?? "" }
    var displayDomains: String { domains.joined(separator: ", ") }

    /// TLD ที่ macOS ต้องมีไฟล์ /etc/resolver/<tld> คู่กัน
    var requiredResolvers: Set<String> {
        Set(domains.compactMap { $0.split(separator: ".").last.map(String.init) })
    }

    func configLine() -> String {
        "\(kind.rawValue)=/\(domains.joined(separator: "/"))/\(target)"
    }
}

/// ไฟล์ .conf หนึ่งไฟล์ พร้อมบรรทัดดิบไว้เขียนกลับแบบไม่ทำลายคอมเมนต์
struct ConfFile: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var lines: [String]
    var entries: [ZoneEntry]

    var name: String { url.lastPathComponent }
    /// ไฟล์ที่ไม่เหลือคำสั่งอะไรแล้ว (มีแต่คอมเมนต์/บรรทัดว่าง)
    var isEffectivelyEmpty: Bool {
        !lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
    }
}
