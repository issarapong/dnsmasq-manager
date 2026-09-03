import Foundation

/// หา path ของ dnsmasq เอง แทนที่จะ hardcode ให้ทำงานทั้งเครื่อง Intel
/// (/usr/local) และ Apple Silicon (/opt/homebrew)
struct Paths {
    var prefix: URL
    var binary: URL
    var mainConf: URL
    var confDir: URL

    static let resolverDir = URL(fileURLWithPath: "/etc/resolver")
    static let launchdLabel = "homebrew.mxcl.dnsmasq"
    static let launchdPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist")
    static var serviceTarget: String { "system/\(launchdLabel)" }

    static func detect() -> Paths? {
        let fm = FileManager.default
        for candidate in ["/usr/local", "/opt/homebrew"] {
            let prefix = URL(fileURLWithPath: candidate)
            let binary = prefix.appendingPathComponent("sbin/dnsmasq")
            guard fm.isExecutableFile(atPath: binary.path) else { continue }
            return Paths(
                prefix: prefix,
                binary: binary,
                mainConf: prefix.appendingPathComponent("etc/dnsmasq.conf"),
                confDir: prefix.appendingPathComponent("etc/dnsmasq.d")
            )
        }
        return nil
    }

    /// คอนฟิกอยู่ใน /usr/local/etc ซึ่งปกติเป็นของ user เขียนได้เลยไม่ต้อง sudo
    var confDirIsUserWritable: Bool {
        FileManager.default.isWritableFile(atPath: confDir.path)
    }
}
