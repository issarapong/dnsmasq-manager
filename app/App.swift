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

/// ผลอ่านสถานะทั้งชุด อ่านนอก main thread แล้วค่อยโยนกลับมาทีเดียว
struct Snapshot: Sendable {
    var zones: [Zone] = []
    var pid: Int?
    var serviceLoaded = false
    var syntaxOK = true
    var syntaxMsg = ""
    var confDir = true
    var orphans: [String] = []
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
        if !orphans.isEmpty || zones.contains(where: { !$0.shadow.isEmpty }) { return .warn }
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
                    Task { await store.remove(zone) }
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
                    .frame(width: 108)
            }
            HStack(spacing: 8) {
                KindPicker(kind: $eKind)
                Spacer()
                Button("ยกเลิก") { editing = false }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Button("บันทึก") {
                    let z = zone
                    let d = eDomain, t = eTarget, k = eKind
                    editing = false
                    Task { await store.update(z, domain: d, target: t, kind: k) }
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
            Pill(text: store.pid.map { "dnsmasq · pid \($0)" } ?? "ไม่ได้รัน",
                 tint: store.pid != nil ? .green : .red)
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

    private var adder: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField("myapp.test", text: $domain)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextField(kind == .server ? "10.0.0.1#5353" : "127.0.0.1", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 108)
                Button("เพิ่ม") { submit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
            }
            HStack(spacing: 8) {
                KindPicker(kind: $kind)
                Text(kind.hint)
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
        let d = domain, t = target, k = kind
        Task {
            await store.add(domain: d, target: t, kind: k)
            if store.flash?.bad != true { domain = ""; target = "" }
        }
    }
}

/// `dnsdev.app/Contents/MacOS/dnsdev --doctor` พิมพ์สถานะที่แอปอ่านได้ออกมาเป็นข้อความ
/// ใช้ตรวจว่าตัวแอปเห็นระบบตรงกับความจริงไหม โดยไม่ต้องเปิด popover
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--doctor") { doctor(); exit(0) }
        DNSDevApp.main()
    }

    static func doctor() {
        let s = Sys.snapshot()
        print("prefix       \(Sys.prefix) (\(Sys.arch))")
        print("dnsmasq      \(s.pid.map { "pid \($0)" } ?? "ไม่ได้รัน")  · launchd \(s.serviceLoaded ? "โหลดแล้ว" : "ไม่ได้โหลด")")
        print("syntax       \(s.syntaxOK ? "OK" : "ผิด: \(s.syntaxMsg)")")
        print("conf-dir     \(s.confDir ? "มี" : "ไม่มี")")
        print("orphans      \(s.orphans.isEmpty ? "—" : s.orphans.joined(separator: ", "))")
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
