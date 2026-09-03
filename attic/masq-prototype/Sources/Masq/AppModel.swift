import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    // MARK: - สภาพแวดล้อม

    let paths: Paths?
    private let controller: DnsmasqController?
    private let zones: ZoneStore?
    private let resolvers = ResolverStore()

    var setupError: String?

    // MARK: - สถานะที่ UI อ่าน

    var status = ServiceStatus()
    var files: [ConfFile] = []
    var resolverEntries: [ResolverStore.Entry] = []
    var probes: [String: DNSProbe.Result] = [:]

    var busyLabel: String?
    var alert: AlertPayload?
    var lastRefresh: Date?

    var entries: [ZoneEntry] { files.flatMap(\.entries) }
    var isBusy: Bool { busyLabel != nil }

    struct AlertPayload: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
    }

    init() {
        guard let paths = Paths.detect() else {
            self.paths = nil
            self.controller = nil
            self.zones = nil
            self.setupError = "หา dnsmasq ไม่เจอใน /usr/local หรือ /opt/homebrew — ติดตั้งด้วย `brew install dnsmasq` ก่อน"
            return
        }
        self.paths = paths
        self.controller = DnsmasqController(paths: paths)
        self.zones = ZoneStore(paths: paths)
    }

    // MARK: - โหลดสถานะ

    /// งานอ่านสถานะทุกอย่างเรียก process ภายนอก เลยโยนออกจาก main actor
    func refresh() async {
        guard let controller, let zones else { return }
        let (newStatus, newFiles, newResolvers) = await Task.detached(priority: .userInitiated) {
            (controller.status(), zones.load(), ResolverStore().load())
        }.value

        status = newStatus
        files = newFiles
        resolverEntries = newResolvers
        lastRefresh = Date()
    }

    func probeAll() async {
        let domains = entries.map(\.primaryDomain)
        guard !domains.isEmpty else { return }
        let results = await Task.detached(priority: .userInitiated) {
            var out: [String: DNSProbe.Result] = [:]
            for d in domains { out[d] = DNSProbe.probe(d) }
            return out
        }.value
        probes.merge(results) { _, new in new }
    }

    func probe(_ domain: String) async -> DNSProbe.Result {
        let r = await Task.detached(priority: .userInitiated) { DNSProbe.probe(domain) }.value
        probes[domain] = r
        return r
    }

    // MARK: - สั่งงาน service

    func perform(_ action: DnsmasqController.Action) async {
        guard let controller else { return }
        await runPrivileged("กำลัง\(action.label) dnsmasq…") {
            try controller.perform(action)
        } onSuccess: {
            AlertPayload(title: "\(action.label)แล้ว", message: "dnsmasq ถูก\(action.label)เรียบร้อย", isError: false)
        }
    }

    func restartAndFlush() async {
        guard let controller else { return }
        await runPrivileged("กำลังรีสตาร์ทและล้างแคช…") {
            try controller.restartAndFlush()
        } onSuccess: {
            AlertPayload(title: "รีสตาร์ทแล้ว", message: "โหลดคอนฟิกใหม่และล้าง DNS cache ของ macOS เรียบร้อย", isError: false)
        }
    }

    func flushCache() async {
        guard let controller else { return }
        await runPrivileged("กำลังล้างแคช…") {
            try controller.flushDNSCache()
        } onSuccess: {
            AlertPayload(title: "ล้างแคชแล้ว", message: "ล้าง DNS cache ของ macOS เรียบร้อย", isError: false)
        }
    }

    // MARK: - โซน

    /// สร้างโซน + ไฟล์ resolver + รีสตาร์ท ในขั้นตอนเดียว เพราะทั้งสามอย่าง
    /// ต้องครบถึงจะใช้งานได้จริง แยกกันทำเมื่อไหร่คนก็ลืมข้อใดข้อหนึ่ง
    func createZone(kind: ZoneEntry.Kind, domain: String, target: String, linkResolver: Bool, restart: Bool) async {
        guard let zones, let controller else { return }
        let tld = String(domain.split(separator: ".").last ?? "")
        let needsResolver = linkResolver && !tld.isEmpty && !resolvers.exists(tld: tld)

        await runPrivileged("กำลังเพิ่มโซน…") { [resolvers] in
            _ = try zones.createZone(kind: kind, domain: domain, target: target)
            if needsResolver { try resolvers.create(tlds: [tld]) }
            if restart { try controller.restartAndFlush() }
        } onSuccess: {
            var done = ["เขียนไฟล์โซนแล้ว"]
            if needsResolver { done.append("สร้าง /etc/resolver/\(tld) แล้ว") }
            if restart { done.append("รีสตาร์ท dnsmasq แล้ว") }
            return AlertPayload(title: "เพิ่ม \(domain) แล้ว", message: done.joined(separator: "\n"), isError: false)
        }
        _ = await probe(domain)
    }

    func updateZone(_ entry: ZoneEntry, kind: ZoneEntry.Kind, domains: [String], target: String, restart: Bool) async {
        guard let zones, let controller else { return }
        await runPrivileged("กำลังบันทึก…") {
            try zones.update(entry, kind: kind, domains: domains, target: target)
            if restart { try controller.restartAndFlush() }
        } onSuccess: { nil }
    }

    func deleteZone(_ entry: ZoneEntry, restart: Bool) async {
        guard let zones, let controller else { return }
        await runPrivileged("กำลังลบ…") {
            try zones.delete(entry)
            if restart { try controller.restartAndFlush() }
        } onSuccess: { nil }
    }

    func saveRawConfig(_ text: String, to url: URL, restart: Bool) async {
        guard let zones, let controller else { return }
        // ตรวจ syntax ก่อนเขียนทับของจริง กันคอนฟิกพังจนบริการไม่ขึ้น
        if let err = await validateDraft(text, replacing: url) {
            alert = AlertPayload(title: "คอนฟิกมีปัญหา", message: err, isError: true)
            return
        }
        await runPrivileged("กำลังบันทึก…") {
            try zones.writeRaw(text, to: url)
            if restart { try controller.restartAndFlush() }
        } onSuccess: {
            AlertPayload(title: "บันทึกแล้ว", message: url.lastPathComponent, isError: false)
        }
    }

    /// เขียนคอนฟิกทั้งชุดลง temp dir แล้วสั่ง `dnsmasq --test` ที่นั่น
    /// จะได้รู้ผลก่อนแตะไฟล์จริง
    private func validateDraft(_ text: String, replacing url: URL) async -> String? {
        guard let paths else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("masq-check-\(UUID().uuidString)")
            let dir = root.appendingPathComponent("dnsmasq.d")
            defer { try? fm.removeItem(at: root) }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                let isMain = url == paths.mainConf
                let mainText = isMain ? text : ((try? String(contentsOf: paths.mainConf, encoding: .utf8)) ?? "")
                // conf-dir ในไฟล์จริงชี้ path เดิม ต้องถอดออกไม่งั้นจะไปอ่านของจริงแทน sandbox
                let mainSanitised = mainText
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("conf-dir=") }
                    .joined(separator: "\n")
                let mainURL = root.appendingPathComponent("dnsmasq.conf")
                try mainSanitised.write(to: mainURL, atomically: true, encoding: .utf8)

                for f in (try? fm.contentsOfDirectory(at: paths.confDir, includingPropertiesForKeys: nil)) ?? []
                where f.pathExtension == "conf" {
                    let body = f == url ? text : ((try? String(contentsOf: f, encoding: .utf8)) ?? "")
                    try body.write(to: dir.appendingPathComponent(f.lastPathComponent), atomically: true, encoding: .utf8)
                }
                if !isMain && !fm.fileExists(atPath: dir.appendingPathComponent(url.lastPathComponent).path) {
                    try text.write(to: dir.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
                }

                let r = Shell.run(paths.binary.path,
                                  ["--test", "-C", mainURL.path, "-7", "\(dir.path),*.conf"], timeout: 10)
                return r.ok ? nil : r.output
            } catch {
                return error.localizedDescription
            }
        }.value
    }

    // MARK: - Resolver

    func createResolvers(_ tlds: [String]) async {
        guard !tlds.isEmpty else { return }
        await runPrivileged("กำลังสร้างไฟล์ resolver…") { [resolvers] in
            try resolvers.create(tlds: tlds)
        } onSuccess: {
            AlertPayload(title: "สร้าง resolver แล้ว",
                         message: tlds.map { "/etc/resolver/\($0)" }.joined(separator: "\n"), isError: false)
        }
    }

    func removeResolver(_ tld: String) async {
        await runPrivileged("กำลังลบ…") { [resolvers] in
            try resolvers.remove(tld: tld)
        } onSuccess: { nil }
    }

    // MARK: - ตรวจสุขภาพ

    /// TLD ที่มีโซนอ้างถึงแต่ยังไม่มีไฟล์ใน /etc/resolver
    var missingResolverTLDs: [String] {
        let have = Set(resolverEntries.filter(\.pointsToLoopback).map(\.tld))
        let need = Set(entries.filter { $0.kind == .address }.flatMap(\.requiredResolvers))
        return need.subtracting(have).sorted()
    }

    /// ไฟล์ resolver ที่ไม่มีโซนไหนใช้แล้ว
    var orphanResolverTLDs: [String] {
        let need = Set(entries.flatMap(\.requiredResolvers))
        return resolverEntries.filter { $0.pointsToLoopback && !need.contains($0.tld) }.map(\.tld).sorted()
    }

    var diagnostics: [Diagnostic] {
        var out: [Diagnostic] = []

        if !status.state.isRunning {
            out.append(Diagnostic(severity: .error, title: "dnsmasq ไม่ได้ทำงาน",
                                  detail: status.summary, fixLabel: "เริ่มบริการ",
                                  fix: { [weak self] in await self?.perform(.start) }))
        } else if !status.listeningOn53 {
            out.append(Diagnostic(severity: .warning, title: "ไม่พบว่าเปิดฟังพอร์ต 53",
                                  detail: "โปรเซสรันอยู่แต่ไม่ได้ bind UDP/53 — อาจมีตัวอื่นยึดพอร์ตไว้",
                                  fixLabel: nil, fix: nil))
        }

        if status.configOK == false {
            out.append(Diagnostic(severity: .error, title: "คอนฟิกมี syntax error",
                                  detail: status.configError ?? "", fixLabel: nil, fix: nil))
        }

        let missing = missingResolverTLDs
        if !missing.isEmpty {
            out.append(Diagnostic(
                severity: .error,
                title: "ขาดไฟล์ resolver: \(missing.map { ".\($0)" }.joined(separator: ", "))",
                detail: "macOS จะไม่ส่ง query ของ TLD นี้มาที่ dnsmasq จนกว่าจะมี /etc/resolver/<tld>",
                fixLabel: "สร้างให้",
                fix: { [weak self] in await self?.createResolvers(missing) }))
        }

        for orphan in orphanResolverTLDs {
            out.append(Diagnostic(severity: .warning, title: "/etc/resolver/\(orphan) ไม่มีโซนใช้แล้ว",
                                  detail: "ชี้มา 127.0.0.1 แต่ไม่มีกฎ address= หรือ server= สำหรับ .\(orphan)",
                                  fixLabel: "ลบไฟล์",
                                  fix: { [weak self] in await self?.removeResolver(orphan) }))
        }

        for entry in entries {
            guard let p = probes[entry.primaryDomain] else { continue }
            if p.viaDnsmasq && !p.viaSystem {
                out.append(Diagnostic(severity: .warning, title: "\(entry.primaryDomain) ตอบเฉพาะตอนถาม dnsmasq ตรง ๆ",
                                      detail: "ระบบยังไม่ route มาที่ dnsmasq — ตรวจ /etc/resolver แล้วลองล้างแคช",
                                      fixLabel: "ล้างแคช",
                                      fix: { [weak self] in await self?.flushCache() }))
            } else if !p.viaDnsmasq {
                out.append(Diagnostic(severity: .error, title: "\(entry.primaryDomain) ไม่ตอบ",
                                      detail: "ถาม @127.0.0.1 แล้วไม่ได้คำตอบ — คอนฟิกอาจยังไม่ถูกโหลด",
                                      fixLabel: "รีสตาร์ท",
                                      fix: { [weak self] in await self?.restartAndFlush() }))
            }
        }

        if out.isEmpty {
            out.append(Diagnostic(severity: .ok, title: "ทุกอย่างเรียบร้อย",
                                  detail: "บริการทำงาน คอนฟิกผ่าน และทุกโซนมี resolver คู่กันครบ",
                                  fixLabel: nil, fix: nil))
        }
        return out
    }

    // MARK: - ตัวช่วย

    private func runPrivileged(_ label: String,
                               _ work: @escaping @Sendable () throws -> Void,
                               onSuccess: () -> AlertPayload?) async {
        busyLabel = label
        defer { busyLabel = nil }

        let success = onSuccess()
        let error: Error? = await Task.detached(priority: .userInitiated) {
            do { try work(); return nil } catch { return error }
        }.value

        if let error {
            // ผู้ใช้กดยกเลิกรหัสผ่านเองไม่ใช่ข้อผิดพลาด ไม่ต้องเด้ง alert
            if case PrivilegedError.cancelled = error {} else {
                alert = AlertPayload(title: "ทำไม่สำเร็จ", message: error.localizedDescription, isError: true)
            }
        } else if let success {
            alert = success
        }
        await refresh()
    }
}
