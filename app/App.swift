// dnsdev — menu bar app จัดการ local dev DNS (dnsmasq + /etc/resolver)
//
// ตัวแอปรันด้วยสิทธิ์ผู้ใช้ปกติ งานที่ต้อง root จะรวบเป็นคำสั่งเดียว
// แล้วขอผ่าน dialog ของ macOS — กรอกรหัสครั้งเดียวต่อหนึ่งการกระทำ

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Model

enum ZoneKind: String, CaseIterable, Sendable {
    case address    // ตอบ IP นี้เองเลย
    case server     // ส่ง query ต่อไปให้ DNS ตัวอื่น

    var directive: String { rawValue }
    var label: String { rawValue }
    var hint: String {
        switch self {
        case .address: "ตอบ IP นี้เอง — wildcard ครอบทุก subdomain ทุกชั้น"
        case .server:  "ส่ง query ต่อไปให้ DNS ตัวอื่น ใส่พอร์ตได้ด้วย 10.0.0.1#5353"
        }
    }
}

struct Zone: Identifiable, Equatable, Sendable {
    var domain: String
    var target: String
    var kind: ZoneKind
    var file: String
    var resolver: String?
    var shadow: [String]
    var id: String { "\(file)|\(kind.rawValue)|\(domain)" }
}

struct Probe: Equatable, Sendable {
    var name: String
    var dnsmasq: String?
    var system: String?
    var bothOK: Bool { dnsmasq != nil && system != nil }
}

enum Health: Sendable { case ok, warn, err }

/// ปัญหาหนึ่งข้อ พร้อมวิธีแก้ที่กดได้จริง — ไม่ใช่แค่บอกให้ไปพิมพ์เอง
struct Issue: Identifiable {
    enum Level { case err, warn }
    let id = UUID()
    var level: Level
    var text: String
    var fixLabel: String?
    var fix: (() -> Void)?
}

// ---- ชั้น https (dnsdevd) ----

struct ProxyRoute: Identifiable, Equatable, Sendable {
    var host: String
    var to: String
    var passthrough: Bool
    var id: String { host }

    /// ปลายทางบนเครื่องเดียวกันย่อเหลือแค่พอร์ต — ":3000" อ่านง่ายกว่า "127.0.0.1:3000"
    var shortTo: String {
        let p = to.split(separator: ":")
        return (p.count == 2 && p[0] == "127.0.0.1") ? ":\(p[1])" : to
    }
    var port: String {
        to.split(separator: ":").last.map(String.init) ?? ""
    }
}

struct ProxyState: Sendable {
    var installed = false
    var pid: Int?
    var https: UInt16 = 443
    var http: UInt16 = 80
    var routes: [ProxyRoute] = []
    var caExists = false
    var caTrusted = false
    /// ใครยึดพอร์ต https อยู่ ถ้าไม่ใช่ dnsdevd เอง — สาเหตุอันดับหนึ่งที่ proxy ไม่ขึ้น
    var portHolder: String?

    var running: Bool { pid != nil }
    var terminates: Bool { routes.contains { !$0.passthrough } }
    func route(for domain: String) -> ProxyRoute? { routes.first { $0.host == domain } }
}

/// ผลอ่านสถานะทั้งชุด อ่านนอก main thread แล้วค่อยโยนกลับมาทีเดียว
struct Snapshot: Sendable {
    var zones: [Zone] = []
    var pid: Int?
    var serviceLoaded = false
    var syntaxOK = true
    var syntaxMsg = ""
    var confDir = true
    var orphans: [String] = []
    var proxy = ProxyState()
}

// MARK: - System glue

enum Sys {
    static let resolverDir = "/etc/resolver"
    static let service = "homebrew.mxcl.dnsmasq"
    static let daemonPlist = "/Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist"
    static var serviceTarget: String { "system/\(service)" }

    /// หา Homebrew prefix ให้ทำงานได้ทั้ง Intel (/usr/local) และ Apple Silicon (/opt/homebrew)
    static let prefix: String = {
        var cands: [String] = []
        if let p = run("/bin/sh", ["-lc", "command -v brew >/dev/null && brew --prefix"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { cands.append(p) }
        cands += ["/opt/homebrew", "/usr/local"]
        for c in cands where FileManager.default.fileExists(atPath: c + "/etc/dnsmasq.conf") { return c }
        for c in cands where FileManager.default.fileExists(atPath: c + "/sbin/dnsmasq") { return c }
        return "/usr/local"
    }()

    static var zoneDir: String { prefix + "/etc/dnsmasq.d" }
    static var confFile: String { prefix + "/etc/dnsmasq.conf" }
    static var binFile: String { prefix + "/sbin/dnsmasq" }
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (-1, "", "\(error)") }

        // อ่านสองท่อพร้อมกัน ถ้าอ่านทีละท่อแล้วอีกท่อเต็ม buffer จะ deadlock
        var od = Data(), ed = Data()
        let g = DispatchGroup()
        for (pipe, sink) in [(o, { od = $0 }), (e, { ed = $0 })] as [(Pipe, (Data) -> Void)] {
            g.enter()
            DispatchQueue.global().async {
                sink((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                g.leave()
            }
        }
        p.waitUntilExit()
        g.wait()
        return (p.terminationStatus,
                String(decoding: od, as: UTF8.self),
                String(decoding: ed, as: UTF8.self))
    }

    /// รันคำสั่ง (รวบหลายงานด้วย && ได้) ผ่าน dialog ขอสิทธิ์ของ macOS
    static func admin(_ cmd: String, prompt: String) -> (ok: Bool, msg: String) {
        let script = "do shell script \"\(esc(cmd))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        let r = run("/usr/bin/osascript", ["-e", script])
        if r.code != 0 {
            let e = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, e.contains("-128") ? "ยกเลิกการกรอกรหัส" : (e.isEmpty ? "คำสั่งล้มเหลว" : e))
        }
        return (true, r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static var reloadCmds: [String] {
        ["launchctl kickstart -k \(serviceTarget)",
         "dscacheutil -flushcache",
         "killall -HUP mDNSResponder"]
    }

    /// ถ้ายังไม่เคยโหลด daemon ต้อง bootstrap ก่อน kickstart ถึงจะมีผล
    static var startCmds: [String] {
        ["launchctl bootstrap system \(daemonPlist) 2>/dev/null || launchctl kickstart -k \(serviceTarget)",
         "dscacheutil -flushcache",
         "killall -HUP mDNSResponder"]
    }

    static var stopCmds: [String] {
        ["launchctl bootout \(serviceTarget)",
         "dscacheutil -flushcache",
         "killall -HUP mDNSResponder"]
    }

    // ---- reads ----

    static func zonePath(_ domain: String) -> String {
        zoneDir + "/" + domain.replacingOccurrences(of: ".", with: "_") + ".conf"
    }

    static func resolverFor(_ domain: String) -> String? {
        var probe = domain
        while !probe.isEmpty {
            if FileManager.default.fileExists(atPath: "\(resolverDir)/\(probe)") { return probe }
            guard let dot = probe.firstIndex(of: ".") else { return nil }
            probe = String(probe[probe.index(after: dot)...])
        }
        return nil
    }

    static func hostsShadow(_ domain: String) -> [String] {
        guard let text = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return [] }
        var hits = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { continue }
            for name in parts.dropFirst() where name == domain || name.hasSuffix("." + domain) {
                hits.insert(name)
            }
        }
        return hits.sorted()
    }

    static func zones() -> [Zone] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: zoneDir) else { return [] }
        var out: [Zone] = []
        for f in files.sorted() where f.hasSuffix(".conf") {
            let path = zoneDir + "/" + f
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                for kind in ZoneKind.allCases {
                    let head = "\(kind.directive)=/"
                    guard line.hasPrefix(head) else { continue }
                    let body = String(line.dropFirst(head.count))
                    let seg = body.split(separator: "/", maxSplits: 1).map(String.init)
                    guard seg.count == 2, !seg[0].isEmpty, !seg[1].isEmpty else { continue }
                    let d = seg[0]
                    out.append(Zone(domain: d, target: seg[1], kind: kind, file: path,
                                    resolver: resolverFor(d), shadow: hostsShadow(d)))
                }
            }
        }
        return out
    }

    static func dnsmasqPID() -> Int? {
        let r = run("/usr/bin/pgrep", ["-f", "\(prefix).*dnsmasq"])
        return r.out.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    /// launchctl print อ่านได้โดยไม่ต้อง root เลยใช้โพลสถานะถี่ ๆ ได้
    static func serviceLoaded() -> Bool {
        run("/bin/launchctl", ["print", serviceTarget]).code == 0
    }

    static func syntaxOK() -> (Bool, String) {
        let r = run(binFile, ["--test", "-C", confFile, "-7", "\(zoneDir),*.conf"])
        let m = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0, m)
    }

    static func hasConfDir() -> Bool {
        guard let t = try? String(contentsOfFile: confFile, encoding: .utf8) else { return false }
        return t.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("conf-dir=") }
    }

    static func orphanResolvers(_ zones: [Zone]) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: resolverDir) else { return [] }
        return files.sorted().filter { name in
            !name.hasPrefix(".") &&
            !zones.contains { $0.domain == name || $0.domain.hasSuffix("." + name) }
        }
    }

    /// อ่านสถานะทุกอย่างในครั้งเดียว ตั้งใจให้เรียกนอก main thread
    static func snapshot() -> Snapshot {
        var s = Snapshot()
        s.zones = zones()
        s.pid = dnsmasqPID()
        s.serviceLoaded = serviceLoaded()
        (s.syntaxOK, s.syntaxMsg) = syntaxOK()
        s.confDir = hasConfDir()
        s.orphans = orphanResolvers(s.zones)
        s.proxy = Prox.state()
        return s
    }

    /// address= ยิง subdomain สุ่มเพื่อพิสูจน์ว่า wildcard ทำงานจริง ไม่ใช่บังเอิญ
    /// มีบรรทัดค้างใน /etc/hosts — ส่วน server= ต้องถามชื่อจริงเพราะปลายทาง
    /// เป็น DNS ตัวอื่นที่ไม่รู้จักชื่อมั่ว
    static func probe(_ domain: String, wildcard: Bool) -> Probe {
        let name = wildcard ? "wildcard-check-\(Int.random(in: 10000...99999)).\(domain)" : domain
        let d = run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "@127.0.0.1", name])
            .out.split(separator: "\n").first.map(String.init)
        let s = run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", name]).out
        var sys: String?
        for line in s.split(separator: "\n") where line.hasPrefix("ip_address:") {
            sys = line.split(separator: " ").last.map(String.init); break
        }
        return Probe(name: name, dnsmasq: d, system: sys)
    }
}

/// ชั้น https — dnsdevd, CA และ route
///
/// ต่างจากชั้น dnsmasq ตรงที่แทบไม่ต้องใช้ root เลย: LaunchAgent เป็นของ user
/// และ macOS ยอมให้ผูกพอร์ตต่ำกว่า 1024 โดยไม่ต้องเป็น root
/// เหลืองานเดียวที่ต้องขอรหัส คือเอา CA เข้า System keychain
enum Prox {
    static let label = "local.dnsdev.proxy"
    static var home: String { NSHomeDirectory() }
    static var stateDir: String { home + "/.config/dnsdev" }
    static var routesFile: String { stateDir + "/routes.json" }
    static var caDir: String { stateDir + "/ca" }
    static var caPem: String { caDir + "/ca.pem" }
    static var logFile: String { stateDir + "/proxy.log" }
    static var agentPlist: String { home + "/Library/LaunchAgents/\(label).plist" }
    static var installedDaemon: String { home + "/.local/libexec/dnsdevd" }

    /// dnsdevd ที่มาพร้อมตัวแอป — build.sh วางไว้ข้าง ๆ ไบนารีหลัก
    /// ใช้ executableURL ไม่ใช่ bundleURL จะได้ทำงานตอนรันจาก build dir ด้วย
    static var bundledDaemon: String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let p = exe.deletingLastPathComponent().appendingPathComponent("dnsdevd").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    // ---- reads ----

    static func pid() -> Int? {
        Sys.run("/usr/bin/pgrep", ["-f", installedDaemon])
            .out.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    static func readRoutes() -> (https: UInt16, http: UInt16, routes: [ProxyRoute]) {
        guard let d = FileManager.default.contents(atPath: routesFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        else { return (443, 80, []) }
        let https = (o["https"] as? NSNumber)?.uint16Value ?? 443
        let http = (o["http"] as? NSNumber)?.uint16Value ?? 80
        let arr = (o["routes"] as? [[String: Any]]) ?? []
        let routes = arr.compactMap { r -> ProxyRoute? in
            guard let h = r["host"] as? String, let t = r["to"] as? String else { return nil }
            return ProxyRoute(host: h, to: t, passthrough: (r["mode"] as? String) == "passthrough")
        }
        return (https, http, routes.sorted { $0.host < $1.host })
    }

    /// เขียนแล้ว rename ทับ — dnsdevd เฝ้าโฟลเดอร์อยู่ จะเห็นการเปลี่ยนครั้งเดียวจบ
    static func writeRoutes(https: UInt16, http: UInt16, _ routes: [ProxyRoute]) throws {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        var body: [String: Any] = ["https": Int(https), "http": Int(http)]
        body["routes"] = routes.sorted { $0.host < $1.host }.map { r -> [String: Any] in
            var e: [String: Any] = ["host": r.host, "to": r.to]
            if r.passthrough { e["mode"] = "passthrough" }
            return e
        }
        let d = try JSONSerialization.data(withJSONObject: body,
                                           options: [.prettyPrinted, .sortedKeys])
        // .atomic เขียนไฟล์ชั่วคราวในโฟลเดอร์เดียวกันแล้ว rename ทับให้เอง
        // ได้ทั้งความอะตอมมิกและสร้างไฟล์ใหม่ได้ตอนยังไม่มี (replaceItemAt ทำอย่างหลังไม่ได้)
        try d.write(to: URL(fileURLWithPath: routesFile), options: .atomic)
    }

    /// เทียบด้วย fingerprint ไม่ใช่ชื่อ — ชื่อ CA ซ้ำกันได้ ลายนิ้วมือไม่ซ้ำ
    static func caTrusted() -> Bool {
        guard FileManager.default.fileExists(atPath: caPem) else { return false }
        let fp = Sys.run("/usr/bin/openssl",
                         ["x509", "-in", caPem, "-noout", "-fingerprint", "-sha1"])
            .out.split(separator: "=").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
        guard let fp, !fp.isEmpty else { return false }
        return Sys.run("/usr/bin/security",
                       ["find-certificate", "-a", "-Z", "/Library/Keychains/System.keychain"])
            .out.contains("SHA-1 hash: " + fp)
    }

    static func portHolder(_ port: UInt16, ours: Int?) -> String? {
        let r = Sys.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
        for line in r.out.split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count > 1, let p = Int(f[1]) else { continue }
            if let ours, p == ours { return nil }
            return "\(f[0]) (pid \(p))"
        }
        return nil
    }

    static func state() -> ProxyState {
        var s = ProxyState()
        s.installed = FileManager.default.fileExists(atPath: agentPlist)
        s.pid = pid()
        (s.https, s.http, s.routes) = readRoutes()
        s.caExists = FileManager.default.fileExists(atPath: caPem)
        s.caTrusted = caTrusted()
        s.portHolder = portHolder(s.https, ours: s.pid)
        return s
    }

    // ---- writes ----

    /// สร้าง CA ถ้ายังไม่มี โดยเรียก dnsdevd เอง — พารามิเตอร์ของ cert
    /// (SKI/AKI, อายุ 397 วัน, EKU) อยู่ที่เดียวใน Proxy.swift จะได้ไม่หลุดจากกัน
    static func ensureCA() -> Bool {
        if FileManager.default.fileExists(atPath: caPem) { return true }
        guard let d = bundledDaemon ?? (FileManager.default.isExecutableFile(atPath: installedDaemon)
                                        ? installedDaemon : nil) else { return false }
        return Sys.run(d, ["--ensure-ca"]).code == 0
    }

    static var plistBody: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key><string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array><string>\(installedDaemon)</string></array>
        \t<key>RunAtLoad</key><true/>
        \t<key>KeepAlive</key><true/>
        \t<key>StandardOutPath</key><string>\(logFile)</string>
        \t<key>StandardErrorPath</key><string>\(logFile)</string>
        \t<key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
    }

    /// ติดตั้งเป็น LaunchAgent — ไม่ต้องขอรหัสผ่านเลย ทุกอย่างอยู่ใน home ของ user
    static func install() -> (ok: Bool, msg: String) {
        guard let src = bundledDaemon else {
            return (false, "หา dnsdevd ที่มากับแอปไม่เจอ — build ใหม่ด้วย app/build.sh")
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (installedDaemon as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: home + "/Library/LaunchAgents",
                                   withIntermediateDirectories: true)
            // คัดลอกจริง ไม่ทำ symlink — ถ้าแอปถูกลบหรือย้าย launchd ต้องยังหาไบนารีเจอ
            if fm.fileExists(atPath: installedDaemon) { try fm.removeItem(atPath: installedDaemon) }
            try fm.copyItem(atPath: src, toPath: installedDaemon)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedDaemon)
            try plistBody.write(toFile: agentPlist, atomically: true, encoding: .utf8)
        } catch {
            return (false, "ติดตั้งไม่สำเร็จ: \(error.localizedDescription)")
        }
        let uid = getuid()
        _ = Sys.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let r = Sys.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentPlist])
        guard r.code == 0 else {
            return (false, "launchctl bootstrap ล้มเหลว: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (true, "")
    }

    static func uninstall() {
        _ = Sys.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: agentPlist)
        try? FileManager.default.removeItem(atPath: installedDaemon)
    }

    static func restart() -> Bool {
        Sys.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"]).code == 0
    }

    static var trustCmd: String {
        "security add-trusted-cert -d -r trustRoot -p ssl -k /Library/Keychains/System.keychain \(caPem)"
    }
    static var untrustCmd: String { "security remove-trusted-cert -d \(caPem)" }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// escape ให้ปลอดภัยเวลาเอาไปใส่ regex ของ sed
    var regexEscaped: String {
        var out = ""
        for c in self {
            if ".^$*+?()[]{}|\\/".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

// MARK: - Validation

enum TLDVerdict { case ok(String), warn(String), blocked(String) }

func verdict(forTLD tld: String) -> TLDVerdict {
    switch tld {
    case "local":
        return .blocked(".local ใช้ไม่ได้ — macOS ส่งไป mDNSResponder (Bonjour) เสมอ "
                      + "query ไม่มีทางถึง dnsmasq  ใช้ .test แทน")
    case "dev":
        return .warn(".dev เป็น gTLD จริงของ Google อยู่ใน HSTS preload "
                   + "browser บังคับ https ต้องมี cert")
    case "localhost":
        return .warn(".localhost macOS resolve ให้เองทุก subdomain อยู่แล้ว "
                   + "ไม่ต้องใช้ dnsmasq (แต่ชี้ได้แค่ 127.0.0.1)")
    case "test":
        return .ok("สงวนถาวรตาม RFC 6761")
    default:
        return .warn(".\(tld) ไม่ใช่ TLD ที่สงวนไว้ อาจถูกขายเป็นโดเมนจริงในอนาคต — .test ปลอดภัยกว่า")
    }
}

func validDomain(_ s: String) -> Bool {
    let labels = s.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
        guard (1...63).contains(l.count), !l.hasPrefix("-"), !l.hasSuffix("-"),
              l.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
    }
    return true
}

func validIP(_ s: String) -> Bool {
    let o = s.split(separator: ".", omittingEmptySubsequences: false)
    return o.count == 4 && o.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0) ?? 999) <= 255 }
}

/// server= ต่อพอร์ตท้าย IP ได้ ส่วน address= ต่อไม่ได้ dnsmasq จะไม่รับ
func validTarget(_ s: String, kind: ZoneKind) -> Bool {
    guard kind == .server else { return validIP(s) }
    let parts = s.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1: return validIP(parts[0])
    case 2: return validIP(parts[0]) && !parts[1].isEmpty
                && parts[1].allSatisfy(\.isNumber) && (Int(parts[1]) ?? 0) > 0 && (Int(parts[1]) ?? 0) <= 65535
    default: return false
    }
}

// MARK: - Login item

/// เปิดแอปเองตอน login ผ่าน SMAppService — ไม่ต้องยุ่งกับ LaunchAgent เอง
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var zones: [Zone] = []
    @Published var pid: Int?
    @Published var serviceLoaded = false
    @Published var syntaxOK = true
    @Published var syntaxMsg = ""
    @Published var confDir = true
    @Published var orphans: [String] = []
    @Published var proxy = ProxyState()
    @Published var probes: [String: Probe] = [:]
    @Published var busy = false
    @Published var loginItem = LoginItem.isEnabled
    @Published var flash: (text: String, bad: Bool)?

    private var poller: Task<Void, Never>?

    init() { startPolling() }

    /// สถานะรวมที่ไอคอนบน menu bar ใช้ — ให้เห็นปัญหาโดยไม่ต้องเปิด popover
    var health: Health {
        if pid == nil || !syntaxOK || !confDir { return .err }
        if zones.contains(where: { $0.resolver == nil }) { return .err }
        if proxy.installed && !proxy.running { return .err }
        if !orphans.isEmpty || zones.contains(where: { !$0.shadow.isEmpty }) { return .warn }
        if proxy.running && proxy.terminates && !proxy.caTrusted { return .warn }
        return .ok
    }

    // MARK: อ่านสถานะ

    func refresh() async {
        // ระหว่างรอ dialog รหัสผ่าน อย่าเพิ่งอ่านทับ ค่าจะกระพริบไปมา
        guard !busy else { return }
        let snap = await Task.detached(priority: .utility) { Sys.snapshot() }.value
        apply(snap)
    }

    private func apply(_ s: Snapshot) {
        zones = s.zones
        pid = s.pid
        serviceLoaded = s.serviceLoaded
        syntaxOK = s.syntaxOK
        syntaxMsg = s.syntaxMsg
        confDir = s.confDir
        orphans = s.orphans
        proxy = s.proxy
    }

    /// โพลเบา ๆ ทุก 15 วิ ให้ไอคอนตามสถานะจริงแม้ไม่ได้เปิด popover
    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: ปัญหา + วิธีแก้

    var issues: [Issue] {
        var out: [Issue] = []

        if pid == nil {
            let hasPlist = FileManager.default.fileExists(atPath: Sys.daemonPlist)
            out.append(.init(
                level: .err,
                text: hasPlist ? "dnsmasq ไม่ได้รัน"
                               : "dnsmasq ไม่ได้รัน และยังไม่เคยติดตั้งเป็น service — "
                               + "รัน `sudo brew services start dnsmasq` หนึ่งครั้งก่อน",
                fixLabel: hasPlist ? "เริ่ม" : nil,
                fix: hasPlist ? { [weak self] in Task { await self?.startService() } } : nil))
        }

        if !syntaxOK {
            out.append(.init(level: .err, text: "config syntax ผิด: \(syntaxMsg)",
                             fixLabel: "เปิดโฟลเดอร์ zone",
                             fix: { NSWorkspace.shared.open(URL(fileURLWithPath: Sys.zoneDir)) }))
        }

        if !confDir {
            out.append(.init(level: .err,
                             text: "dnsmasq.conf ไม่มี conf-dir= — ไฟล์ zone จะไม่ถูกอ่านเลย",
                             fixLabel: "เพิ่มให้",
                             fix: { [weak self] in Task { await self?.addConfDir() } }))
        }

        for z in zones where z.resolver == nil {
            let tld = String(z.domain.split(separator: ".").last ?? "")
            out.append(.init(
                level: .err,
                text: "\(z.domain) ไม่มี /etc/resolver — dnsmasq ตอบถูกแต่ macOS ไม่ส่ง query มาให้",
                fixLabel: "สร้าง",
                fix: { [weak self] in Task { await self?.createResolver(tld) } }))
        }

        for z in zones where !z.shadow.isEmpty {
            let names = z.shadow
            out.append(.init(
                level: .warn,
                text: "\(z.domain) ถูก /etc/hosts ทับ (\(names.joined(separator: ", "))) — hosts ชนะ DNS เสมอ",
                fixLabel: "ปิดบรรทัดนั้น",
                fix: { [weak self] in Task { await self?.commentOutHosts(names) } }))
        }

        for o in orphans {
            out.append(.init(
                level: .warn,
                text: "/etc/resolver/\(o) ไม่มี zone รองรับ — query จะ forward ออก internet เปล่า ๆ",
                fixLabel: "ลบ",
                fix: { [weak self] in Task { await self?.removeResolver(o) } }))
        }

        if proxy.installed, !proxy.running {
            let why = proxy.portHolder.map { " — :\(proxy.https) ถูก \($0) ยึดอยู่" } ?? ""
            out.append(.init(level: .err, text: "dnsdevd ไม่ได้รัน\(why)",
                             fixLabel: proxy.portHolder == nil ? "เริ่ม" : "ดู log",
                             fix: proxy.portHolder == nil
                                ? { [weak self] in Task { await self?.restartProxy() } }
                                : { NSWorkspace.shared.open(URL(fileURLWithPath: Prox.logFile)) }))
        }

        if !proxy.installed, !proxy.routes.isEmpty {
            out.append(.init(level: .warn,
                             text: "มี route ของ proxy อยู่ \(proxy.routes.count) อัน แต่ยังไม่ได้ติดตั้ง dnsdevd",
                             fixLabel: "ติดตั้ง",
                             fix: { [weak self] in Task { await self?.installProxy() } }))
        }

        if proxy.running, proxy.terminates, !proxy.caTrusted {
            out.append(.init(level: .warn,
                             text: "cert ของ dnsdev ยังไม่ถูกติดตั้งในเครื่อง — browser จะเตือนทุกครั้งที่เปิด https",
                             fixLabel: "ติดตั้ง cert",
                             fix: { [weak self] in Task { await self?.trustCA() } }))
        }
        return out
    }

    // MARK: ตัวช่วย

    private func say(_ t: String, bad: Bool = false) {
        flash = (t, bad)
        Task { try? await Task.sleep(for: .seconds(5)); if flash?.text == t { flash = nil } }
    }

    /// ขอสิทธิ์ครั้งเดียวแล้วอ่านสถานะใหม่ — ทุก action ที่แตะ root ผ่านทางนี้
    ///
    /// dialog รหัสผ่านบล็อกจนกว่าจะกรอกเสร็จ เลยต้องรันนอก main thread
    /// ไม่งั้น UI ค้างและสถานะ busy ไม่ทันแสดง
    @discardableResult
    private func withAdmin(_ cmds: [String], prompt: String,
                           onFail: (() -> Void)? = nil,
                           success: String? = nil) async -> Bool {
        guard !cmds.isEmpty else { return true }
        let cmd = cmds.joined(separator: " && ")
        busy = true
        let r = await Task.detached(priority: .userInitiated) { Sys.admin(cmd, prompt: prompt) }.value
        busy = false
        guard r.ok else {
            onFail?()
            say(onFail == nil ? r.msg : "ย้อนกลับแล้ว: \(r.msg)", bad: true)
            return false
        }
        await refresh()
        if let success { say(success) }
        return true
    }

    // MARK: คุม service

    func startService() async {
        await withAdmin(Sys.startCmds, prompt: "dnsdev — เริ่ม dnsmasq", success: "เริ่ม dnsmasq แล้ว")
    }

    func stopService() async {
        await withAdmin(Sys.stopCmds, prompt: "dnsdev — หยุด dnsmasq", success: "หยุด dnsmasq แล้ว")
    }

    func restart() async {
        await withAdmin(Sys.reloadCmds, prompt: "dnsdev — restart dnsmasq", success: "restart + flush cache แล้ว")
    }

    func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItem = LoginItem.isEnabled
            say(loginItem ? "จะเปิด dnsdev เองตอน login" : "ปิดการเปิดเองตอน login แล้ว")
        } catch {
            loginItem = LoginItem.isEnabled
            say("ตั้งไม่สำเร็จ: \(error.localizedDescription)", bad: true)
        }
    }

    // MARK: resolver / hosts / conf-dir

    func createResolver(_ tld: String) async {
        await withAdmin(["mkdir -p \(Sys.resolverDir)",
                         "printf 'nameserver 127.0.0.1\\n' > \(Sys.resolverDir)/\(tld)"] + Sys.reloadCmds,
                        prompt: "dnsdev — สร้าง /etc/resolver/\(tld)",
                        success: "สร้าง /etc/resolver/\(tld) แล้ว")
    }

    func removeResolver(_ tld: String) async {
        await withAdmin(["rm -f \(Sys.resolverDir)/\(tld)"] + Sys.reloadCmds,
                        prompt: "dnsdev — ลบ /etc/resolver/\(tld)",
                        success: "ลบ /etc/resolver/\(tld) แล้ว")
    }

    /// คอมเมนต์บรรทัดใน /etc/hosts แทนที่จะลบทิ้ง — ย้อนกลับได้เอง
    /// และสำรองไฟล์เดิมไว้ที่ /etc/hosts.dnsdev.bak ก่อนเสมอ
    func commentOutHosts(_ names: [String]) async {
        var cmds = ["cp /etc/hosts /etc/hosts.dnsdev.bak"]
        for n in names {
            let pat = n.regexEscaped
            cmds.append("sed -i '' -E '/^[[:space:]]*[^#].*[[:space:]]\(pat)([[:space:]]|$)/s|^|# dnsdev ปิดไว้ |' /etc/hosts")
        }
        cmds += ["dscacheutil -flushcache", "killall -HUP mDNSResponder"]
        await withAdmin(cmds, prompt: "dnsdev — ปิดบรรทัดใน /etc/hosts",
                        success: "ปิดบรรทัดแล้ว (สำรองไว้ที่ /etc/hosts.dnsdev.bak)")
    }

    func addConfDir() async {
        let line = "conf-dir=\(Sys.zoneDir)/,*.conf"
        // ไฟล์ใน brew prefix ปกติเป็นของ user เขียนตรงได้ ไม่ต้องกวนรหัสผ่าน
        if FileManager.default.isWritableFile(atPath: Sys.confFile),
           let cur = try? String(contentsOfFile: Sys.confFile, encoding: .utf8) {
            let body = cur.hasSuffix("\n") ? cur + line + "\n" : cur + "\n" + line + "\n"
            do { try body.write(toFile: Sys.confFile, atomically: true, encoding: .utf8) }
            catch { return say("เขียน dnsmasq.conf ไม่ได้: \(error.localizedDescription)", bad: true) }
            await withAdmin(Sys.reloadCmds, prompt: "dnsdev — เพิ่ม conf-dir=", success: "เพิ่ม conf-dir= แล้ว")
        } else {
            await withAdmin(["printf '%s\\n' \(Sys.esc(line)) >> \(Sys.confFile)"] + Sys.reloadCmds,
                            prompt: "dnsdev — เพิ่ม conf-dir=", success: "เพิ่ม conf-dir= แล้ว")
        }
    }

    // MARK: ชั้น https

    /// ติดตั้ง proxy ไม่ต้องขอรหัสผ่าน — LaunchAgent กับไบนารีอยู่ใน home ทั้งคู่
    func installProxy() async {
        busy = true
        let r = await Task.detached(priority: .userInitiated) { () -> (ok: Bool, msg: String) in
            _ = Prox.ensureCA()
            return Prox.install()
        }.value
        busy = false
        await refresh()
        if r.ok {
            say(proxy.caTrusted ? "ติดตั้ง proxy แล้ว" : "ติดตั้ง proxy แล้ว — เหลือติดตั้ง cert อีกขั้น")
        } else {
            say(r.msg, bad: true)
        }
    }

    func uninstallProxy() async {
        busy = true
        await Task.detached(priority: .userInitiated) { Prox.uninstall() }.value
        busy = false
        await refresh()
        say("ถอด proxy แล้ว — CA กับ route ยังอยู่")
    }

    func restartProxy() async {
        busy = true
        let ok = await Task.detached(priority: .userInitiated) { Prox.restart() }.value
        busy = false
        await refresh()
        say(ok ? "restart proxy แล้ว" : "restart ไม่สำเร็จ — ติดตั้งหรือยัง?", bad: !ok)
    }

    /// ขั้นเดียวในชั้นนี้ที่ต้องใช้ root — เอา CA เข้า System keychain
    func trustCA() async {
        let made = await Task.detached(priority: .userInitiated) { Prox.ensureCA() }.value
        guard made else { return say("สร้าง CA ไม่สำเร็จ — build dnsdevd หรือยัง?", bad: true) }
        await withAdmin([Prox.trustCmd],
                        prompt: "dnsdev — ติดตั้ง cert ของ dnsdev เข้าเครื่อง",
                        success: "ติดตั้ง cert แล้ว — https ในเครื่องจะไม่ขึ้นเตือนอีก")
    }

    func untrustCA() async {
        await withAdmin([Prox.untrustCmd],
                        prompt: "dnsdev — เอา cert ของ dnsdev ออกจากเครื่อง",
                        success: "เอา cert ออกแล้ว")
    }

    // MARK: route

    func setRoute(_ domain: String, port rawPort: String, passthrough: Bool = false) async {
        let p = rawPort.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard let n = Int(p), (1...65535).contains(n) else {
            return say("พอร์ตไม่ถูกต้อง: \(rawPort)", bad: true)
        }
        var routes = proxy.routes.filter { $0.host != domain }
        routes.append(ProxyRoute(host: domain, to: "127.0.0.1:\(n)", passthrough: passthrough))
        await writeRoutes(routes, note: "https://\(domain) → :\(n)")
    }

    func removeRoute(_ domain: String) async {
        guard proxy.route(for: domain) != nil else { return }
        await writeRoutes(proxy.routes.filter { $0.host != domain },
                          note: "เอา \(domain) ออกจาก proxy แล้ว")
    }

    private func writeRoutes(_ routes: [ProxyRoute], note: String) async {
        let https = proxy.https, http = proxy.http
        do {
            try await Task.detached(priority: .userInitiated) {
                try Prox.writeRoutes(https: https, http: http, routes)
            }.value
        } catch {
            return say("เขียน routes.json ไม่ได้: \(error.localizedDescription)", bad: true)
        }
        await refresh()
        say(note)
    }

    // MARK: zone

    func add(domain rawDomain: String, target rawTarget: String, kind: ZoneKind) async {
        let domain = rawDomain.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let target = rawTarget.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "127.0.0.1"
        guard validDomain(domain) else { return say("รูปแบบโดเมนไม่ถูกต้อง: \(domain)", bad: true) }
        guard validTarget(target, kind: kind) else {
            return say(kind == .server ? "ปลายทางไม่ถูกต้อง: \(target) (ใช้ ip หรือ ip#port)"
                                       : "IP ไม่ถูกต้อง: \(target)", bad: true)
        }
        guard !zones.contains(where: { $0.domain == domain }) else {
            return say("มี zone \(domain) อยู่แล้ว — กดแก้ไขที่รายการด้านล่าง", bad: true)
        }

        let tld = String(domain.split(separator: ".").last!)
        var warning: String?
        switch verdict(forTLD: tld) {
        case .blocked(let m): return say(m, bad: true)
        case .warn(let m): warning = m
        case .ok: break
        }

        let path = Sys.zonePath(domain)
        let prev = try? String(contentsOfFile: path, encoding: .utf8)
        guard writeZone(path: path, domain: domain, target: target, kind: kind) else { return }

        func rollback() { restoreFile(path, prev) }
        let (ok, msg) = Sys.syntaxOK()
        if !ok { rollback(); return say("config syntax ผิด ยกเลิกแล้ว: \(msg)", bad: true) }

        var cmds: [String] = []
        if Sys.resolverFor(domain) == nil {
            cmds.append("mkdir -p \(Sys.resolverDir) && printf 'nameserver 127.0.0.1\\n' > \(Sys.resolverDir)/\(tld)")
        }
        cmds += Sys.reloadCmds

        guard await withAdmin(cmds, prompt: "dnsdev — เพิ่ม \(domain)", onFail: rollback) else { return }
        probes[domain] = await runProbe(domain, kind: kind)
        say(warning ?? "เพิ่ม \(domain) → \(target) แล้ว", bad: warning != nil)
    }

    /// แก้ zone ที่มีอยู่ — เปลี่ยนได้ทั้งโดเมน ปลายทาง และชนิด
    /// ถ้าโดเมนเปลี่ยน ชื่อไฟล์ก็เปลี่ยนตาม ต้องย้ายไฟล์และเช็ค resolver ใหม่ด้วย
    func update(_ zone: Zone, domain rawDomain: String, target rawTarget: String, kind: ZoneKind) async {
        let domain = rawDomain.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let target = rawTarget.trimmingCharacters(in: .whitespaces)
        guard validDomain(domain) else { return say("รูปแบบโดเมนไม่ถูกต้อง: \(domain)", bad: true) }
        guard validTarget(target, kind: kind) else {
            return say(kind == .server ? "ปลายทางไม่ถูกต้อง: \(target) (ใช้ ip หรือ ip#port)"
                                       : "IP ไม่ถูกต้อง: \(target)", bad: true)
        }
        if domain != zone.domain, zones.contains(where: { $0.domain == domain }) {
            return say("มี zone \(domain) อยู่แล้ว", bad: true)
        }
        if domain == zone.domain, target == zone.target, kind == zone.kind { return }

        let tld = String(domain.split(separator: ".").last!)
        if case .blocked(let m) = verdict(forTLD: tld) { return say(m, bad: true) }

        let newPath = Sys.zonePath(domain)
        let oldPath = zone.file
        let prevNew = try? String(contentsOfFile: newPath, encoding: .utf8)
        let prevOld = try? String(contentsOfFile: oldPath, encoding: .utf8)

        guard writeZone(path: newPath, domain: domain, target: target, kind: kind) else { return }
        if newPath != oldPath { try? FileManager.default.removeItem(atPath: oldPath) }

        func rollback() {
            restoreFile(newPath, prevNew)
            if newPath != oldPath { restoreFile(oldPath, prevOld) }
        }
        let (ok, msg) = Sys.syntaxOK()
        if !ok { rollback(); return say("config syntax ผิด ยกเลิกแล้ว: \(msg)", bad: true) }

        var cmds: [String] = []
        if Sys.resolverFor(domain) == nil {
            cmds.append("mkdir -p \(Sys.resolverDir) && printf 'nameserver 127.0.0.1\\n' > \(Sys.resolverDir)/\(tld)")
        }
        // TLD เดิมอาจไม่มีใครใช้แล้วหลังเปลี่ยนโดเมน
        let oldTLD = String(zone.domain.split(separator: ".").last ?? "")
        if oldTLD != tld, !Sys.zones().contains(where: { $0.domain == oldTLD || $0.domain.hasSuffix("." + oldTLD) }),
           FileManager.default.fileExists(atPath: "\(Sys.resolverDir)/\(oldTLD)") {
            cmds.append("rm -f \(Sys.resolverDir)/\(oldTLD)")
        }
        cmds += Sys.reloadCmds

        guard await withAdmin(cmds, prompt: "dnsdev — แก้ไข \(zone.domain)", onFail: rollback) else { return }
        probes[zone.domain] = nil
        probes[domain] = await runProbe(domain, kind: kind)
        say("แก้เป็น \(domain) → \(target) (\(kind.label)) แล้ว")
    }

    func remove(_ zone: Zone) async {
        let path = zone.file
        guard let backup = try? String(contentsOfFile: path, encoding: .utf8) else {
            return say("ไม่มีไฟล์ zone: \(path)", bad: true)
        }
        try? FileManager.default.removeItem(atPath: path)

        let tld = String(zone.domain.split(separator: ".").last ?? "")
        var cmds: [String] = []
        let stillUsed = Sys.zones().contains { $0.domain == tld || $0.domain.hasSuffix("." + tld) }
        if FileManager.default.fileExists(atPath: "\(Sys.resolverDir)/\(tld)"), !stillUsed {
            cmds.append("rm -f \(Sys.resolverDir)/\(tld)")
        }
        cmds += Sys.reloadCmds

        guard await withAdmin(cmds, prompt: "dnsdev — ลบ \(zone.domain)",
                              onFail: { restoreFile(path, backup) }) else { return }
        probes[zone.domain] = nil
        say("ลบ \(zone.domain) แล้ว")
    }

    func test(_ zone: Zone) async {
        probes[zone.domain] = await runProbe(zone.domain, kind: zone.kind)
    }

    private func runProbe(_ domain: String, kind: ZoneKind) async -> Probe {
        await Task.detached(priority: .userInitiated) {
            Sys.probe(domain, wildcard: kind == .address)
        }.value
    }

    private func writeZone(path: String, domain: String, target: String, kind: ZoneKind) -> Bool {
        let note = kind == .address
            ? "# \(domain) — wildcard ครอบทุก subdomain ทุกชั้น"
            : "# \(domain) — ส่ง query ต่อไปที่ \(target)"
        let body = "\(note)\n# สร้างโดย dnsdev\n\(kind.directive)=/\(domain)/\(target)\n"
        do { try body.write(toFile: path, atomically: true, encoding: .utf8); return true }
        catch { say("เขียนไฟล์ไม่ได้: \(error.localizedDescription)", bad: true); return false }
    }
}

/// คืนไฟล์กลับสภาพเดิม — ไม่มีเนื้อหาเดิมแปลว่าเมื่อก่อนไม่มีไฟล์นี้
private func restoreFile(_ path: String, _ previous: String?) {
    if let previous { try? previous.write(toFile: path, atomically: true, encoding: .utf8) }
    else { try? FileManager.default.removeItem(atPath: path) }
}

// MARK: - UI

struct Pill: View {
    var text: String
    var tint: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// ไอคอนบน menu bar — คงรูปโลกไว้เสมอเพื่อให้จำได้ แล้วบอกสถานะด้วยสี
/// ปกติปล่อยเป็น template ให้ปรับตามพื้นหลัง menu bar เอง มีปัญหาถึงค่อยลงสี
enum MenuIcon {
    static func image(_ h: Health) -> NSImage {
        let name = "globe.badge.chevron.backward"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "dnsdev")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        switch h {
        case .ok:
            let img = base.withSymbolConfiguration(size) ?? base
            img.isTemplate = true
            return img
        case .warn, .err:
            let tint: NSColor = h == .err ? .systemRed : .systemOrange
            let cfg = size.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            let img = base.withSymbolConfiguration(cfg) ?? base
            img.isTemplate = false
            return img
        }
    }
}

struct ProbeView: View {
    var p: Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ยิง \(p.name)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            row("ชั้น dnsmasq", p.dnsmasq)
            row("ชั้นระบบ (ที่ app ใช้จริง)", p.system)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
    func row(_ label: String, _ val: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: val != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(val != nil ? .green : .red)
                .font(.system(size: 10))
            Text(label).font(.system(size: 11))
            Text(val ?? "ไม่ตอบ")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// ตัวเลือก address / server ขนาดเล็ก ใช้ทั้งตอนเพิ่มและตอนแก้
struct KindPicker: View {
    @Binding var kind: ZoneKind
    var body: some View {
        Picker("", selection: $kind) {
            ForEach(ZoneKind.allCases, id: \.self) { k in
                Text(k.label).tag(k)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 132)
        .font(.system(size: 11))
    }
}

struct ZoneRow: View {
    @EnvironmentObject var store: Store
    var zone: Zone
    @State private var hover = false
    @State private var editing = false
    @State private var eDomain = ""
    @State private var eTarget = ""
    @State private var ePort = ""
    @State private var eKind: ZoneKind = .address

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing { editor } else { summary }
            if let p = store.probes[zone.domain], !editing { ProbeView(p: p) }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(hover || editing ? Color.primary.opacity(0.05) : .clear)
        .onHover { hover = $0 }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.kind == .address ? "*.\(zone.domain)" : zone.domain)
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(zone.kind == .address ? "→" : "⇢") \(zone.target)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if zone.kind == .server { Pill(text: "server", tint: .blue) }
            if let r = store.proxy.route(for: zone.domain) {
                Button {
                    if let u = URL(string: "https://\(zone.domain)") { NSWorkspace.shared.open(u) }
                } label: {
                    Pill(text: r.passthrough ? "https \(r.shortTo) ⇢" : "https \(r.shortTo)",
                         tint: store.proxy.caTrusted && store.proxy.running ? .green : .orange)
                }
                .buttonStyle(.plain)
                .help(store.proxy.running
                      ? "เปิด https://\(zone.domain)"
                      : "dnsdevd ไม่ได้รัน — route นี้ยังไม่มีผล")
            }
            if let r = zone.resolver {
                Pill(text: "/etc/resolver/\(r)", tint: .green)
            } else {
                Pill(text: "ไม่มี resolver", tint: .red)
            }
            if !zone.shadow.isEmpty { Pill(text: "hosts ทับ \(zone.shadow.count)", tint: .orange) }
            if hover {
                Button("ทดสอบ") { Task { await store.test(zone) } }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Button("แก้ไข") { beginEdit() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Button {
                    Task { await store.remove(zone); await store.removeRoute(zone.domain) }
                } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("โดเมน", text: $eDomain)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextField(eKind == .server ? "10.0.0.1#5353" : "127.0.0.1", text: $eTarget)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 96)
                if eKind == .address {
                    TextField(":3000", text: $ePort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 54)
                        .help("พอร์ตของ dev server — ลบให้ว่างเพื่อเอาออกจาก proxy")
                }
            }
            HStack(spacing: 8) {
                KindPicker(kind: $eKind)
                Spacer()
                Button("ยกเลิก") { editing = false }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Button("บันทึก") {
                    let z = zone
                    let d = eDomain.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    let t = eTarget, k = eKind, pt = ePort.trimmingCharacters(in: .whitespaces)
                    editing = false
                    Task {
                        await store.update(z, domain: d, target: t, kind: k)
                        guard store.flash?.bad != true else { return }
                        // โดเมนอาจเปลี่ยนชื่อ route เก่าจึงต้องถูกเก็บกวาดเสมอ
                        if d != z.domain { await store.removeRoute(z.domain) }
                        if k == .address, !pt.isEmpty { await store.setRoute(d, port: pt) }
                        else { await store.removeRoute(d) }
                    }
                }
                .font(.system(size: 11))
                .disabled(store.busy)
            }
            Text(eKind.hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func beginEdit() {
        eDomain = zone.domain
        eTarget = zone.target
        ePort = store.proxy.route(for: zone.domain)?.port ?? ""
        eKind = zone.kind
        editing = true
    }
}

struct IssueRow: View {
    var issue: Issue
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: issue.level == .err ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(issue.level == .err ? .red : .orange)
                .font(.system(size: 10))
                .padding(.top, 1)
            Text(issue.text).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let label = issue.fixLabel, let fix = issue.fix {
                Button(label, action: fix)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
    }
}

/// วัดความสูงเนื้อในของลิสต์ ส่งขึ้นมาให้ ContentView กำหนดกรอบ
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var domain = ""
    @State private var target = ""
    @State private var port = ""
    @State private var kind: ZoneKind = .address
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            adder
            Divider()
            list
            if let f = store.flash {
                Divider()
                Text(f.text)
                    .font(.system(size: 11))
                    .foregroundStyle(f.bad ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 440)
        .opacity(store.busy ? 0.55 : 1)
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("dnsdev").font(.system(size: 14, weight: .bold))
            Pill(text: store.pid.map { "dnsmasq · \($0)" } ?? "dnsmasq หยุด",
                 tint: store.pid != nil ? .green : .red)
            if store.proxy.installed || !store.proxy.routes.isEmpty {
                Pill(text: proxyPillText, tint: proxyPillTint)
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16) }
            Menu {
                if store.pid == nil {
                    Button("เริ่ม dnsmasq") { Task { await store.startService() } }
                } else {
                    Button("restart dnsmasq") { Task { await store.restart() } }
                    Button("หยุด dnsmasq") { Task { await store.stopService() } }
                }
                Divider()
                if store.proxy.installed {
                    Button(store.proxy.running ? "restart proxy (https)" : "เริ่ม proxy (https)") {
                        Task { await store.restartProxy() }
                    }
                    Button("ถอด proxy ออก") { Task { await store.uninstallProxy() } }
                } else {
                    Button("ติดตั้ง proxy (https)") { Task { await store.installProxy() } }
                }
                if store.proxy.caTrusted {
                    Button("เอา cert ของ dnsdev ออกจากเครื่อง") { Task { await store.untrustCA() } }
                } else {
                    Button("ติดตั้ง cert เข้าเครื่อง…") { Task { await store.trustCA() } }
                }
                Button("เปิดโฟลเดอร์ cert") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Prox.caDir))
                }
                if FileManager.default.fileExists(atPath: Prox.logFile) {
                    Button("เปิด log ของ proxy") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Prox.logFile))
                    }
                }
                Divider()
                Toggle("เปิด dnsdev เองตอน login", isOn: Binding(
                    get: { store.loginItem },
                    set: { store.setLoginItem($0) }))
                Button("เปิดโฟลเดอร์ zone") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Sys.zoneDir))
                }
                Divider()
                Text("\(Sys.prefix) · \(Sys.arch)")
                Divider()
                Button("ออกจากโปรแกรม") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 22)
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 9)
    }

    /// pill ของชั้น https บอกสามสถานะที่ต่างกันจริง ๆ: ไม่รัน / รันแต่ยังไม่มี cert / พร้อมใช้
    private var proxyPillText: String {
        if !store.proxy.installed { return "https ยังไม่ติดตั้ง" }
        if !store.proxy.running { return "https หยุด" }
        return store.proxy.caTrusted ? "https :\(store.proxy.https)" : "https · ยังไม่มี cert"
    }
    private var proxyPillTint: Color {
        if !store.proxy.installed || !store.proxy.running { return .red }
        return store.proxy.caTrusted ? .green : .orange
    }

    private var adder: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField("myapp.test", text: $domain)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextField(kind == .server ? "10.0.0.1#5353" : "127.0.0.1", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 96)
                if kind == .address {
                    TextField(":3000", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 54)
                        .help("ใส่พอร์ตของ dev server แล้วเปิด https://โดเมน ได้เลยโดยไม่ต้องพิมพ์พอร์ต")
                }
                Button("เพิ่ม") { submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
            }
            HStack(spacing: 8) {
                KindPicker(kind: $kind)
                Text(kind == .address && !port.isEmpty
                     ? "https://\(domain.isEmpty ? "โดเมน" : domain) → 127.0.0.1:\(port.trimmingCharacters(in: CharacterSet(charactersIn: ":")))"
                     : kind.hint)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.zones.isEmpty {
                    Text("ยังไม่มี zone — เพิ่มด้านบนได้เลย")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                } else {
                    ForEach(store.zones) { z in
                        ZoneRow(zone: z)
                        Divider().opacity(0.4)
                    }
                }
                let issues = store.issues
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ตรวจสุขภาพ")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(issues) { IssueRow(issue: $0) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
            })
        }
        // ScrollView ไม่มีความสูงในตัวเอง ถ้าให้แค่ maxHeight มันจะยุบเหลือ 0
        // ในหน้าต่างที่ย่อตามเนื้อหาอย่าง popover — ต้องวัดเนื้อในแล้วกำหนดความสูงตรง ๆ
        .frame(height: min(max(listHeight, 1), 330))
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
    }

    private func submit() {
        let d = domain.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let t = target, k = kind, pt = port
        Task {
            await store.add(domain: d, target: t, kind: k)
            guard store.flash?.bad != true else { return }
            // zone เข้าแล้วค่อยผูก route — ถ้า zone ล้มก็ไม่ควรมี route ค้าง
            if k == .address, !pt.trimmingCharacters(in: .whitespaces).isEmpty {
                await store.setRoute(d, port: pt)
            }
            domain = ""; target = ""; port = ""
        }
    }
}

/// `dnsdev.app/Contents/MacOS/dnsdev --doctor` พิมพ์สถานะที่แอปอ่านได้ออกมาเป็นข้อความ
/// ใช้ตรวจว่าตัวแอปเห็นระบบตรงกับความจริงไหม โดยไม่ต้องเปิด popover
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--doctor") { doctor(); exit(0) }
        // --popover เปิด popover ให้เองตอนขึ้น ใช้ถ่ายรูป/ดีบักหน้าตาโดยไม่ต้องขอ
        // assistive access (กด NSStatusBarButton ของตัวเองไม่นับเป็นการควบคุมแอปอื่น)
        if CommandLine.arguments.contains("--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { clickStatusItem() }
        }
        DNSDevApp.main()
    }

    static func clickStatusItem() {
        func find(_ v: NSView?) -> NSStatusBarButton? {
            guard let v else { return nil }
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        var clicked = false
        for w in NSApp.windows where !clicked {
            if let b = find(w.contentView) { b.performClick(nil); clicked = true }
        }
        guard clicked else {
            FileHandle.standardError.write(Data("หา NSStatusBarButton ไม่เจอ\n".utf8)); return
        }
        // popover ขึ้นเป็นหน้าต่างใหม่ รอให้ layout เสร็จก่อนค่อยวัด
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            var out = "หน้าต่างหลังกด:\n"
            for w in NSApp.windows where w.isVisible {
                out += "  \(type(of: w))  \(Int(w.frame.width))x\(Int(w.frame.height))\n"
            }
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    static func doctor() {
        let s = Sys.snapshot()
        print("prefix       \(Sys.prefix) (\(Sys.arch))")
        print("dnsmasq      \(s.pid.map { "pid \($0)" } ?? "ไม่ได้รัน")  · launchd \(s.serviceLoaded ? "โหลดแล้ว" : "ไม่ได้โหลด")")
        print("syntax       \(s.syntaxOK ? "OK" : "ผิด: \(s.syntaxMsg)")")
        print("conf-dir     \(s.confDir ? "มี" : "ไม่มี")")
        print("orphans      \(s.orphans.isEmpty ? "—" : s.orphans.joined(separator: ", "))")
        let px = s.proxy
        print("proxy        " + (px.installed
            ? (px.running ? "pid \(px.pid!)" : "ติดตั้งแล้วแต่ไม่ได้รัน")
            : "ยังไม่ติดตั้ง")
            + "  · https :\(px.https) http :\(px.http)"
            + (px.portHolder.map { "  · :\(px.https) ถูก \($0) ยึด" } ?? ""))
        print("cert         " + (px.caExists
            ? (px.caTrusted ? "ติดตั้งในเครื่องแล้ว" : "มี CA แต่ยังไม่ได้ติดตั้งเข้าเครื่อง")
            : "ยังไม่มี CA"))
        print("routes       \(px.routes.count)")
        for r in px.routes {
            print("  https://\(r.host) → \(r.to)" + (r.passthrough ? "  [passthrough]" : ""))
        }
        print("zones        \(s.zones.count)")
        for z in s.zones {
            print("  \(z.kind.directive)=/\(z.domain)/\(z.target)"
                + "  resolver=\(z.resolver ?? "ไม่มี")"
                + (z.shadow.isEmpty ? "" : "  hosts ทับ=\(z.shadow.joined(separator: ","))")
                + "  [\((z.file as NSString).lastPathComponent)]")
            let p = Sys.probe(z.domain, wildcard: z.kind == .address)
            print("    probe \(p.name) → dnsmasq=\(p.dnsmasq ?? "ไม่ตอบ") ระบบ=\(p.system ?? "ไม่ตอบ")")
        }
    }
}

struct DNSDevApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            Image(nsImage: MenuIcon.image(store.health))
                .renderingMode(.original)
        }
        .menuBarExtraStyle(.window)
    }
}
