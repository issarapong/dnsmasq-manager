import Foundation

/// ยิง query จริงเพื่อพิสูจน์ว่าโซนใช้งานได้ ไม่ใช่แค่คอนฟิกดูถูก
enum DNSProbe {
    struct Result: Equatable {
        var answers: [String]
        var viaDnsmasq: Bool     // ถามตรงไปที่ 127.0.0.1 แล้วตอบ
        var viaSystem: Bool      // ถามผ่าน resolver ของระบบแล้วตอบ (ต้องมี /etc/resolver)
        var error: String?

        var isHealthy: Bool { viaDnsmasq && viaSystem }
    }

    static func probe(_ domain: String) -> Result {
        let direct = dig(domain, server: "127.0.0.1")
        let system = dig(domain, server: nil)
        return Result(
            answers: direct.isEmpty ? system : direct,
            viaDnsmasq: !direct.isEmpty,
            viaSystem: !system.isEmpty,
            error: direct.isEmpty && system.isEmpty ? "ไม่มีคำตอบ" : nil
        )
    }

    private static func dig(_ domain: String, server: String?) -> [String] {
        var args = ["+short", "+time=2", "+tries=1"]
        if let server { args.append("@\(server)") }
        args.append(domain)
        let r = Shell.run("/usr/bin/dig", args, timeout: 8)
        return r.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
