import Foundation

/// อ่าน/เขียนโซนในไฟล์ .conf โดยรักษาคอมเมนต์และบรรทัดอื่นไว้ครบ
/// (แก้เฉพาะบรรทัดที่เกี่ยวข้อง ไม่ generate ไฟล์ใหม่ทับ)
struct ZoneStore {
    let paths: Paths

    // MARK: - อ่าน

    func load() -> [ConfFile] {
        var files: [ConfFile] = []
        if let main = readConf(at: paths.mainConf) { files.append(main) }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: paths.confDir, includingPropertiesForKeys: nil)) ?? []
        let confs = contents
            .filter { $0.pathExtension == "conf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for url in confs {
            if let f = readConf(at: url) { files.append(f) }
        }
        return files
    }

    func allEntries() -> [ZoneEntry] { load().flatMap(\.entries) }

    private func readConf(at url: URL) -> ConfFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        // ไฟล์ที่ลงท้ายด้วย newline จะได้ element ว่างท้ายสุด ตัดออกแล้วค่อยเติมกลับตอนเขียน
        if lines.last == "" { lines.removeLast() }

        var entries: [ZoneEntry] = []
        for (i, line) in lines.enumerated() {
            if let e = Self.parse(line: line, file: url, lineIndex: i) { entries.append(e) }
        }
        return ConfFile(url: url, lines: lines, entries: entries)
    }

    /// แกะ `address=/a.test/b.test/1.2.3.4` — โดเมนกี่ตัวก็ได้ ตัวสุดท้ายคือปลายทาง
    static func parse(line: String, file: URL, lineIndex: Int) -> ZoneEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }

        for kind in ZoneEntry.Kind.allCases {
            let prefix = "\(kind.rawValue)=/"
            guard trimmed.hasPrefix(prefix) else { continue }
            let body = String(trimmed.dropFirst(prefix.count))
            let parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }

            let target = parts[parts.count - 1]
            let domains = parts.dropLast().filter { !$0.isEmpty }
            guard !domains.isEmpty, !target.isEmpty else { return nil }

            return ZoneEntry(kind: kind, domains: Array(domains), target: target,
                             file: file, lineIndex: lineIndex, raw: line)
        }
        return nil
    }

    // MARK: - เขียน

    /// ตั้งชื่อไฟล์จากโดเมน เพื่อให้ยังคง "หนึ่งโซนหนึ่งไฟล์" ตามที่คอนฟิกหลักกำหนดไว้
    func suggestedFileName(for domain: String) -> String {
        let safe = domain.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return (safe.isEmpty ? "zone" : safe) + ".conf"
    }

    func fileURL(named name: String) -> URL {
        paths.confDir.appendingPathComponent(name.hasSuffix(".conf") ? name : name + ".conf")
    }

    /// สร้างไฟล์โซนใหม่พร้อมหัวคอมเมนต์อธิบายว่ากฎนี้ครอบอะไรบ้าง
    func createZone(kind: ZoneEntry.Kind, domain: String, target: String, fileName: String? = nil) throws -> URL {
        let url = fileURL(named: fileName ?? suggestedFileName(for: domain))
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ZoneStoreError.fileExists(url.lastPathComponent)
        }
        let note = kind == .address
            ? "# \(domain) — wildcard ครอบทุก subdomain ทุกชั้นอัตโนมัติ"
            : "# \(domain) — ส่ง query ต่อไปที่ \(target)"
        let body = """
        \(note)
        #
        # สร้างโดย Masq เมื่อ \(Self.timestamp())
        \(kind.rawValue)=/\(domain)/\(target)

        """
        try write(text: body, to: url)
        return url
    }

    func update(_ entry: ZoneEntry, kind: ZoneEntry.Kind, domains: [String], target: String) throws {
        guard var file = readConf(at: entry.file) else { throw ZoneStoreError.unreadable(entry.file.lastPathComponent) }
        guard file.lines.indices.contains(entry.lineIndex) else { throw ZoneStoreError.lineMoved }

        // รักษาย่อหน้าเดิมของบรรทัดไว้
        let indent = String(entry.raw.prefix { $0 == " " || $0 == "\t" })
        var updated = entry
        updated.kind = kind
        updated.domains = domains
        updated.target = target
        file.lines[entry.lineIndex] = indent + updated.configLine()

        try write(text: file.lines.joined(separator: "\n") + "\n", to: file.url)
    }

    /// ลบบรรทัดโซน ถ้าไฟล์เหลือแต่คอมเมนต์ก็ลบทั้งไฟล์ ไม่ทิ้งขยะไว้
    func delete(_ entry: ZoneEntry) throws {
        guard var file = readConf(at: entry.file) else { throw ZoneStoreError.unreadable(entry.file.lastPathComponent) }
        guard file.lines.indices.contains(entry.lineIndex) else { throw ZoneStoreError.lineMoved }

        file.lines.remove(at: entry.lineIndex)
        if file.isEffectivelyEmpty && file.url != paths.mainConf {
            try remove(at: file.url)
        } else {
            try write(text: file.lines.joined(separator: "\n") + "\n", to: file.url)
        }
    }

    func writeRaw(_ text: String, to url: URL) throws {
        try write(text: text.hasSuffix("\n") ? text : text + "\n", to: url)
    }

    // MARK: - I/O

    /// เขียนตรงถ้าเป็นเจ้าของไฟล์ ไม่งั้นค่อยขอสิทธิ์ admin
    private func write(text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let canWriteDirect = FileManager.default.fileExists(atPath: url.path)
            ? FileManager.default.isWritableFile(atPath: url.path)
            : FileManager.default.isWritableFile(atPath: dir.path)

        if canWriteDirect {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("masq-\(UUID().uuidString).conf")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Privileged.run("/bin/mkdir -p \(Privileged.quote(dir.path)); "
            + "/bin/cp \(Privileged.quote(tmp.path)) \(Privileged.quote(url.path)); "
            + "/bin/chmod 644 \(Privileged.quote(url.path))")
    }

    private func remove(at url: URL) throws {
        if FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: url)
        } else {
            try Privileged.run("/bin/rm -f \(Privileged.quote(url.path))")
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

enum ZoneStoreError: LocalizedError {
    case fileExists(String)
    case unreadable(String)
    case lineMoved

    var errorDescription: String? {
        switch self {
        case .fileExists(let n): "มีไฟล์ \(n) อยู่แล้ว"
        case .unreadable(let n): "อ่านไฟล์ \(n) ไม่ได้"
        case .lineMoved:         "ไฟล์ถูกแก้จากที่อื่นระหว่างทาง กด Refresh แล้วลองใหม่"
        }
    }
}
