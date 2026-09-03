import Foundation

/// คุมตัว service: อ่านสถานะ, start/stop/restart, ตรวจ syntax, ล้าง DNS cache
struct DnsmasqController {
    let paths: Paths

    // MARK: - อ่านสถานะ

    func status() -> ServiceStatus {
        var s = ServiceStatus()
        s.state = launchdState()
        s.version = version()
        s.listeningOn53 = isListeningOn53()
        let check = testConfig()
        s.configOK = check.ok
        s.configError = check.ok ? nil : check.output
        return s
    }

    /// `launchctl print` อ่านได้โดยไม่ต้อง root เลยใช้ได้ตอนโพลสถานะ
    private func launchdState() -> ServiceStatus.State {
        let r = Shell.run("/bin/launchctl", ["print", Paths.serviceTarget], timeout: 8)
        guard r.ok else {
            if r.output.contains("Could not find service") { return .notLoaded }
            return .unknown(r.output.isEmpty ? "อ่านสถานะไม่ได้" : r.output)
        }
        let pid = firstMatch(in: r.stdout, pattern: #"^\s*pid = (\d+)"#).flatMap { Int32($0) }
        let state = firstMatch(in: r.stdout, pattern: #"^\s*state = (\S+)"#)

        if let pid { return .running(pid: pid) }
        if state == "running" {
            // state บอกว่ารันแต่ยังไม่มี pid — ถามจาก process list แทน
            if let pid = runningPID() { return .running(pid: pid) }
        }
        return .loadedNotRunning
    }

    private func runningPID() -> Int32? {
        let r = Shell.run("/usr/bin/pgrep", ["-f", paths.binary.path], timeout: 5)
        return r.stdout.split(separator: "\n").first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func isListeningOn53() -> Bool {
        // -n/-P กันไม่ให้ lsof ไป resolve ชื่อ ซึ่งจะวนกลับมาหา dnsmasq เองแล้วค้าง
        let r = Shell.run("/usr/sbin/lsof", ["-nP", "-iUDP:53", "-sUDP:*"], timeout: 8)
        return r.stdout.localizedCaseInsensitiveContains("dnsmasq")
    }

    func version() -> String? {
        let r = Shell.run(paths.binary.path, ["-v"], timeout: 5)
        return firstMatch(in: r.stdout, pattern: #"Dnsmasq version (\S+)"#)
    }

    /// ตรวจ syntax ทั้ง main conf และ conf-dir ก่อน restart จริง
    func testConfig() -> CommandResult {
        Shell.run(paths.binary.path,
                  ["--test", "-C", paths.mainConf.path, "-7", "\(paths.confDir.path),*.conf"],
                  timeout: 10)
    }

    // MARK: - สั่งงาน (ต้องสิทธิ์ admin)

    enum Action: String {
        case start, stop, restart

        var label: String {
            switch self {
            case .start: "เริ่ม"
            case .stop: "หยุด"
            case .restart: "รีสตาร์ท"
            }
        }
    }

    func perform(_ action: Action) throws {
        let plist = Privileged.quote(Paths.launchdPlist.path)
        let target = Paths.serviceTarget
        let script: String
        switch action {
        case .start:
            script = "/bin/launchctl bootstrap system \(plist) 2>/dev/null || /bin/launchctl kickstart \(target)"
        case .stop:
            script = "/bin/launchctl bootout \(target)"
        case .restart:
            // kickstart -k ฆ่าตัวเก่าแล้วเริ่มใหม่ ถ้ายังไม่ได้โหลดก็ bootstrap ให้
            script = "/bin/launchctl kickstart -k \(target) 2>/dev/null || /bin/launchctl bootstrap system \(plist)"
        }
        try Privileged.run(script)
    }

    /// รีสตาร์ท + ล้าง cache ของ macOS ในการยืนยันรหัสผ่านครั้งเดียว
    func restartAndFlush() throws {
        let plist = Privileged.quote(Paths.launchdPlist.path)
        try Privileged.run("""
        /bin/launchctl kickstart -k \(Paths.serviceTarget) 2>/dev/null || /bin/launchctl bootstrap system \(plist); \
        /usr/bin/dscacheutil -flushcache; \
        /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
        """)
    }

    func flushDNSCache() throws {
        try Privileged.run("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true")
    }
}

/// ดึงกลุ่มแรกของ regex ออกมา ใช้ซ้ำหลายที่เลยแยกไว้
func firstMatch(in text: String, pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}
