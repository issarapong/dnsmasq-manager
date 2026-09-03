import Foundation

/// จัดการ /etc/resolver/<tld> — ถ้าไม่มีไฟล์นี้ macOS จะไม่ยอมส่ง query
/// ของ TLD นั้นมาที่ dnsmasq เลย แม้คอนฟิก dnsmasq จะถูกทุกอย่าง
struct ResolverStore {
    struct Entry: Identifiable, Hashable {
        var id: String { tld }
        var tld: String
        var nameserver: String?
        var pointsToLoopback: Bool { nameserver == "127.0.0.1" || nameserver == "::1" }
    }

    func load() -> [Entry] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Paths.resolverDir, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .map { Entry(tld: $0.lastPathComponent, nameserver: nameserver(in: $0)) }
            .sorted { $0.tld < $1.tld }
    }

    func exists(tld: String) -> Bool {
        FileManager.default.fileExists(atPath: Paths.resolverDir.appendingPathComponent(tld).path)
    }

    private func nameserver(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return firstMatch(in: text, pattern: #"^\s*nameserver\s+(\S+)"#)
    }

    /// สร้างหลาย TLD ในการยืนยันรหัสผ่านครั้งเดียว
    func create(tlds: [String], nameserver: String = "127.0.0.1") throws {
        let cmds = tlds.map { tld -> String in
            let path = Privileged.quote(Paths.resolverDir.appendingPathComponent(tld).path)
            return "/bin/echo 'nameserver \(nameserver)' > \(path); /bin/chmod 644 \(path)"
        }
        guard !cmds.isEmpty else { return }
        try Privileged.run("/bin/mkdir -p /etc/resolver; " + cmds.joined(separator: "; "))
    }

    func remove(tld: String) throws {
        let path = Privileged.quote(Paths.resolverDir.appendingPathComponent(tld).path)
        try Privileged.run("/bin/rm -f \(path)")
    }
}
