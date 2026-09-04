// dnsdevd — reverse proxy ของ dnsdev: ทำให้ https://myapp.test เปิดได้โดยไม่ต้องพิมพ์พอร์ต
//
// ทำไมต้องมีสองโหมด:
//   terminate   — dev server บน Mac พูด HTTP ธรรมดา  dnsdevd ถือ cert ให้
//   passthrough — VM/คอนเทนเนอร์ที่มี cert ของตัวเองอยู่แล้ว (เช่น nginx ใน Lima)
//                 ห้าม terminate ไม่งั้น cert เดิมหายหมด อ่านแค่ SNI แล้วส่ง TLS ดิบต่อ
//
// เพราะต้องรู้ SNI *ก่อน* ตัดสินใจ :443 จึงเป็น listener TCP ดิบ แล้วส่งต่อสองทาง:
//   passthrough → ยิงเข้า backend ตรง ๆ
//   terminate   → ส่งเข้า TLS listener ภายในบน loopback แล้วค่อยแตกเป็น HTTP
// ค่าใช้จ่ายของ hop ภายในบน loopback แทบเป็นศูนย์ แลกกับโค้ดที่แยกส่วนกันสะอาด
//
// หลัง route ได้แล้วจะไม่แตะ byte อีกเลย ปล่อยเป็น pipe สองทาง — WebSocket (HMR),
// SSE, chunked, upgrade อะไรก็ผ่านหมดโดยไม่ต้องเขียน HTTP stack เอง
import Foundation
import Network
import Security

// ---------- paths ----------
// DNSDEV_STATE ให้ชี้ที่เก็บไปที่อื่นได้ — ใช้ตอนทดสอบ จะได้ไม่ไปยุ่งของจริง
let stateDir = ProcessInfo.processInfo.environment["DNSDEV_STATE"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/dnsdev", isDirectory: true)
let routesFile = stateDir.appendingPathComponent("routes.json")
let caDir = stateDir.appendingPathComponent("ca", isDirectory: true)
let caCert = caDir.appendingPathComponent("ca.pem")
let caKey = caDir.appendingPathComponent("ca.key")
let OPENSSL = "/usr/bin/openssl"   // ติดมากับ macOS — ไม่พึ่ง Homebrew

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(ts) \(s)\n".data(using: .utf8)!)
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

// ---------- config ----------
struct Route: Codable {
    var host: String
    var to: String
    var mode: String?          // "terminate" (default) | "passthrough"
    var passthrough: Bool { mode == "passthrough" }
}

struct Config: Codable {
    var https: UInt16?
    var http: UInt16?
    var routes: [Route]

    static let empty = Config(https: 443, http: 80, routes: [])

    static func load() -> Config {
        guard let d = try? Data(contentsOf: routesFile) else { return .empty }
        guard let c = try? JSONDecoder().decode(Config.self, from: d) else {
            log("routes.json พัง — ใช้ค่าว่างไปก่อน")
            return .empty
        }
        return c
    }

    // dnsmasq ใช้กฎ "ยาวกว่าชนะ" — ที่นี่ก็ต้องเหมือนกัน ไม่งั้นคนใช้จะงง
    // route "myapp.test" ครอบ subdomain ทุกชั้นเองด้วย ให้ตรงกับ wildcard zone ฝั่ง DNS
    func match(_ host: String) -> Route? {
        let h = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        var best: Route?
        for r in routes {
            let rh = r.host.hasPrefix("*.") ? String(r.host.dropFirst(2)) : r.host.lowercased()
            if h == rh || h.hasSuffix("." + rh) {
                if best == nil || rh.count > (best!.host.hasPrefix("*.")
                    ? best!.host.count - 2 : best!.host.count) { best = r }
            }
        }
        return best
    }

    /// ชื่อตั้งต้นที่ cert ควรครอบ — เฉพาะ route ที่เรา terminate เอง
    /// (passthrough ไม่ต้อง เพราะปลายทางถือ cert ของตัวเอง)
    var terminateHosts: [String] {
        routes.filter { !$0.passthrough }
              .map { $0.host.hasPrefix("*.") ? String($0.host.dropFirst(2)) : $0.host }
    }
}

/// SAN ของชื่อหนึ่ง = ตัวมันเอง + ลูกอีกหนึ่งชั้น
/// ลึกกว่านั้น (a.b.myapp.test) ต้องออก cert ใหม่ตอนเห็น SNI จริง เพราะ TLS
/// ไม่ยอมรับ wildcard หลายชั้น (`*.*.x` ใช้ไม่ได้) ขณะที่ DNS ฝั่ง dnsmasq ครอบทุกชั้น
func sanNames(for hosts: Set<String>) -> [String] {
    var out = ["localhost"]
    for h in hosts.sorted() { out.append(h); out.append("*." + h) }
    var seen = Set<String>()
    return out.filter { seen.insert($0).inserted }
}

// ---------- CA + leaf cert ----------
enum CertError: Error { case failed(String) }

func ensureCA() throws {
    try FileManager.default.createDirectory(at: caDir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: caCert.path),
       FileManager.default.fileExists(atPath: caKey.path) { return }
    log("สร้าง CA ใหม่ที่ \(caCert.path)")
    let r = run(OPENSSL, [
        "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
        "-keyout", caKey.path, "-out", caCert.path,
        "-subj", "/CN=dnsdev local CA/O=dnsdev",
        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        "-addext", "subjectKeyIdentifier=hash",
    ])
    guard r.code == 0 else { throw CertError.failed("สร้าง CA ไม่สำเร็จ: \(r.out)") }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
}

/// ออก leaf ครอบทุกชื่อ แล้วคืน SecIdentity โดยไม่แตะ Keychain เลย
/// (SecPKCS12Import คืน identity ในหน่วยความจำ — ไม่มี prompt ไม่ทิ้งขยะไว้ในพวงกุญแจ)
func makeIdentity(sans: [String]) throws -> SecIdentity {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dnsdev-leaf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let key = tmp.appendingPathComponent("leaf.key").path
    let csr = tmp.appendingPathComponent("leaf.csr").path
    let crt = tmp.appendingPathComponent("leaf.pem").path
    let ext = tmp.appendingPathComponent("leaf.ext").path
    let p12 = tmp.appendingPathComponent("leaf.p12").path

    // SKI/AKI ไม่ใช่ของประดับ — OpenSSL 3 (Node/Python/curl ที่ลิงก์กับมัน) ปฏิเสธ
    // cert ที่ไม่มี AKI ด้วย "Missing Authority Key Identifier" ทั้งที่ Safari ผ่านสบาย
    let sanLine = sans.map { "DNS:\($0)" }.joined(separator: ",") + ",IP:127.0.0.1,IP:::1"
    let extBody = """
    basicConstraints=CA:FALSE
    keyUsage=critical,digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectKeyIdentifier=hash
    authorityKeyIdentifier=keyid,issuer
    subjectAltName=\(sanLine)
    """
    try extBody.write(toFile: ext, atomically: true, encoding: .utf8)

    var r = run(OPENSSL, ["req", "-newkey", "rsa:2048", "-nodes",
                          "-keyout", key, "-out", csr, "-subj", "/CN=dnsdev"])
    guard r.code == 0 else { throw CertError.failed("สร้าง CSR ไม่สำเร็จ: \(r.out)") }

    // 397 วัน — Apple ปฏิเสธ server cert ที่อายุเกิน 398 วัน
    r = run(OPENSSL, ["x509", "-req", "-in", csr, "-CA", caCert.path, "-CAkey", caKey.path,
                      "-CAcreateserial", "-out", crt, "-days", "397", "-sha256", "-extfile", ext])
    guard r.code == 0 else { throw CertError.failed("เซ็น leaf ไม่สำเร็จ: \(r.out)") }

    let pass = UUID().uuidString   // ใช้ครั้งเดียวแล้วทิ้งไปพร้อมโฟลเดอร์ชั่วคราว
    r = run(OPENSSL, ["pkcs12", "-export", "-out", p12, "-inkey", key, "-in", crt,
                      "-passout", "pass:\(pass)"])
    guard r.code == 0 else { throw CertError.failed("แพ็ก p12 ไม่สำเร็จ: \(r.out)") }

    guard let data = FileManager.default.contents(atPath: p12) else {
        throw CertError.failed("อ่าน p12 ไม่ได้")
    }
    var items: CFArray?
    let st = SecPKCS12Import(data as CFData,
                             [kSecImportExportPassphrase as String: pass] as CFDictionary,
                             &items)
    guard st == errSecSuccess,
          let arr = items as? [[String: Any]],
          let identity = arr.first?[kSecImportItemIdentity as String]
    else { throw CertError.failed("SecPKCS12Import ล้มเหลว: \(st)") }
    return (identity as! SecIdentity)
}

// ---------- อ่าน SNI จาก ClientHello ----------
// ต้องรู้ปลายทางก่อนแตะ TLS จึงต้องแกะ ClientHello เอง (ยาวไม่เกิน ~2KB เสมอในทางปฏิบัติ)
func parseSNI(_ d: Data) -> String? {
    let b = [UInt8](d)
    var i = 0
    func u8() -> Int? { guard i < b.count else { return nil }; defer { i += 1 }; return Int(b[i]) }
    func u16() -> Int? { guard i + 1 < b.count else { return nil }; defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i+1]) }
    func skip(_ n: Int) -> Bool { guard i + n <= b.count else { return false }; i += n; return true }

    guard u8() == 0x16 else { return nil }        // handshake record
    guard skip(2), let recLen = u16(), recLen > 0 else { return nil }
    guard u8() == 0x01 else { return nil }        // ClientHello
    guard skip(3), skip(2), skip(32) else { return nil }   // len, version, random
    guard let sidLen = u8(), skip(sidLen) else { return nil }
    guard let csLen = u16(), skip(csLen) else { return nil }
    guard let compLen = u8(), skip(compLen) else { return nil }
    guard let extTotal = u16() else { return nil }

    let extEnd = min(i + extTotal, b.count)
    while i + 4 <= extEnd {
        guard let type = u16(), let len = u16() else { return nil }
        if type == 0x0000 {                        // server_name
            let end = min(i + len, b.count)
            guard skip(2) else { return nil }      // server_name_list length
            guard let nameType = u8(), nameType == 0, let nameLen = u16() else { return nil }
            guard i + nameLen <= end else { return nil }
            return String(decoding: b[i..<(i + nameLen)], as: UTF8.self)
        }
        guard skip(len) else { return nil }
    }
    return nil
}

// ---------- ท่อสองทาง ----------
// หลังจุดนี้ไม่สนใจว่าเป็น HTTP, WebSocket หรือ TLS ดิบ — ส่ง byte ต่อไปเฉย ๆ
func pipe(_ a: NWConnection, _ b: NWConnection) {
    func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
            if let d = data, !d.isEmpty {
                to.send(content: d, completion: .contentProcessed { _ in })
            }
            if done || err != nil { from.cancel(); to.cancel(); return }
            pump(from, to)
        }
    }
    pump(a, b); pump(b, a)
}

func connect(to target: String, then ready: @escaping (NWConnection?) -> Void) {
    let parts = target.split(separator: ":")
    let host = String(parts.first ?? "127.0.0.1")
    let port = UInt16(parts.count > 1 ? String(parts[1]) : "80") ?? 80
    guard let p = NWEndpoint.Port(rawValue: port) else { ready(nil); return }
    let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    var settled = false
    c.stateUpdateHandler = { st in
        switch st {
        case .ready: if !settled { settled = true; ready(c) }
        case .failed(let e):
            if !settled { settled = true; log("ต่อ \(target) ไม่ได้: \(e)"); ready(nil) }
        case .cancelled: if !settled { settled = true; ready(nil) }
        default: break
        }
    }
    c.start(queue: .global())
}

func reply(_ conn: NWConnection, _ status: String, _ body: String) {
    let b = body.data(using: .utf8)!
    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
        + "Content-Length: \(b.count)\r\nConnection: close\r\n\r\n"
    conn.send(content: head.data(using: .utf8)! + b,
              completion: .contentProcessed { _ in conn.cancel() })
}

/// อ่านจนกว่าจะเจอเงื่อนไข แล้วส่งก้อนที่สะสมไว้ทั้งหมดต่อ (ไม่ทิ้ง byte)
func readUntil(_ conn: NWConnection, cap: Int = 65536,
               done: @escaping (Data) -> Bool,
               finish: @escaping (Data?) -> Void) {
    var buf = Data()
    func step() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isDone, err in
            if let d = data { buf.append(d) }
            if done(buf) { finish(buf); return }
            if isDone || err != nil || buf.count >= cap { finish(buf.isEmpty ? nil : buf); return }
            step()
        }
    }
    step()
}

// ---------- ตัวเซิร์ฟเวอร์ ----------
final class Proxy {
    private var config = Config.empty
    private var portListeners: [NWListener] = []
    private let q = DispatchQueue(label: "dnsdev.proxy")
    // listener ต้องอยู่คนละคิวกับ q เด็ดขาด — reload() รันบน q แล้วรอ listener
    // รายงานตัว ถ้าใช้คิวเดียวกันมันจะรอตัวเองจนหมดเวลา แล้ว proxy ดับทั้งตัว
    private let lq = DispatchQueue(label: "dnsdev.listeners", attributes: .concurrent)

    // cert ออกตามชื่อที่เห็นจริง — ป้องกันด้วย lock เพราะถูกเรียกจาก connection queue
    private let lock = NSLock()
    private var covered = Set<String>()      // ชื่อที่ cert ปัจจุบันครอบอยู่
    private var tlsListener: NWListener?
    private var tlsPort: UInt16 = 0
    private var retired: [NWListener] = []   // listener เก่า เก็บไว้ให้ connection ที่ยังวิ่งอยู่

    func start() {
        reload()
        watch()
    }

    // MARK: reload
    private func reload() {
        let new = Config.load()
        config = new
        portListeners.forEach { $0.cancel() }
        portListeners = []

        lock.lock()
        covered = Set(new.terminateHosts)
        lock.unlock()

        do {
            try ensureCA()
            try rebuildTLS()
        } catch {
            log("เตรียม cert ไม่สำเร็จ: \(error)")
            return
        }

        let httpsPort = new.https ?? 443
        let httpPort = new.http ?? 80
        for host in ["127.0.0.1", "::1"] {
            if let l = makeListener(host: host, port: httpsPort, handler: handleTLS) { portListeners.append(l) }
            if let l = makeListener(host: host, port: httpPort, handler: handlePlain) { portListeners.append(l) }
        }
        log("โหลดใหม่: \(new.routes.count) route · https :\(httpsPort) · http :\(httpPort)")
        for r in new.routes {
            log("  \(r.host) → \(r.to)\(r.passthrough ? "  [passthrough]" : "")")
        }
        watchFile()
    }

    /// ให้แน่ใจว่า cert ครอบชื่อนี้แล้ว คืนพอร์ตของ TLS listener ที่ใช้ได้
    /// ชื่อที่ไม่มี route ก็ออก cert ให้เหมือนกัน — จะได้ terminate แล้วตอบหน้า
    /// "ไม่มี route" ให้อ่านออกใน browser แทนที่จะปิดใส่หน้าเฉย ๆ
    private func ensureCovered(_ host: String) -> UInt16 {
        lock.lock()
        if covered.contains(host), tlsPort != 0 {
            defer { lock.unlock() }
            return tlsPort
        }
        covered.insert(host)
        lock.unlock()
        do { try rebuildTLS() } catch { log("ออก cert ให้ \(host) ไม่ได้: \(error)") }
        lock.lock(); defer { lock.unlock() }
        return tlsPort
    }

    private func rebuildTLS() throws {
        lock.lock()
        let names = sanNames(for: covered)
        let old = tlsListener
        lock.unlock()

        let identity = try makeIdentity(sans: names)
        let (l, port) = try startInternalTLS(identity: identity)

        lock.lock()
        tlsListener = l
        tlsPort = port
        if let old {
            // อย่าตัดทันที — WebSocket/SSE ที่ยังวิ่งอยู่บน listener เก่าจะขาดกลางคัน
            retired.append(old)
            q.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let dead = self.retired; self.retired = []; self.lock.unlock()
                dead.forEach { $0.cancel() }
            }
        }
        lock.unlock()
    }

    /// ต้องเฝ้าทั้งโฟลเดอร์และตัวไฟล์ ไม่ใช่อย่างใดอย่างหนึ่ง:
    ///
    /// - โฟลเดอร์เห็นการสร้าง/เปลี่ยนชื่อ/ลบ — คือท่าที่ CLI, แอป และเว็บใช้
    ///   (เขียนไฟล์ชั่วคราวแล้ว rename ทับ) ซึ่งเปลี่ยน inode ทุกครั้ง
    /// - ตัวไฟล์เห็นการเขียนทับ inode เดิม — คือท่าที่ editor กับ `echo >` ใช้
    ///   ซึ่งไม่แตะสารบัญของโฟลเดอร์เลย ถ้าเฝ้าแต่โฟลเดอร์จะเงียบสนิท
    private func watch() {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let fd = open(stateDir.path, O_EVTONLY)
        guard fd >= 0 else { log("เฝ้า \(stateDir.path) ไม่ได้"); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: q)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
        watchFile()
    }

    /// ผูกใหม่ทุกครั้งหลัง reload — การเขียนแบบ atomic เปลี่ยน inode
    /// fd เดิมจะค้างชี้ไฟล์เก่าที่ไม่มีใครใช้แล้ว
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(routesFile.path, O_EVTONLY)
        guard fd >= 0 else { return }   // ยังไม่มีไฟล์ — โฟลเดอร์จะเห็นตอนถูกสร้าง
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: q)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileWatcher = src
    }

    /// หน่วงสั้น ๆ กัน reload ซ้ำ — ทั้งจากการเขียนหลายจังหวะ และจากการที่
    /// การเขียนครั้งเดียวปลุกทั้ง watcher ของโฟลเดอร์และของไฟล์พร้อมกัน
    private func scheduleReload() {
        pendingReload?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = w
        q.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    // MARK: listeners
    private func makeListener(host: String, port: UInt16,
                              handler: @escaping (NWConnection) -> Void) -> NWListener? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: p)
        guard let l = try? NWListener(using: params) else {
            log("ผูก \(host):\(port) ไม่ได้ — มีคนยึดอยู่?")
            return nil
        }
        l.newConnectionHandler = { c in
            c.stateUpdateHandler = { if case .ready = $0 { handler(c) } }
            c.start(queue: .global())
        }
        l.stateUpdateHandler = { if case .failed(let e) = $0 { log("listener \(host):\(port) ล้ม: \(e)") } }
        l.start(queue: lq)
        return l
    }

    /// TLS listener ภายใน: รับต่อจาก :443 เฉพาะ route ที่เรา terminate เอง
    private func startInternalTLS(identity: SecIdentity) throws -> (NWListener, UInt16) {
        let tls = NWProtocolTLS.Options()
        guard let sid = sec_identity_create(identity) else {
            throw CertError.failed("sec_identity_create ล้มเหลว")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sid)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let l = try NWListener(using: params)
        l.newConnectionHandler = { c in
            c.stateUpdateHandler = { if case .ready = $0 { self.handleDecrypted(c) } }
            c.start(queue: .global())
        }
        let sem = DispatchSemaphore(value: 0)
        var bound: UInt16 = 0
        l.stateUpdateHandler = { st in
            if case .ready = st { bound = l.port?.rawValue ?? 0; sem.signal() }
            if case .failed(let e) = st { log("TLS listener ภายในล้ม: \(e)"); sem.signal() }
        }
        l.start(queue: lq)
        _ = sem.wait(timeout: .now() + 5)
        guard bound != 0 else { throw CertError.failed("TLS listener ภายในไม่ขึ้น") }
        return (l, bound)
    }

    // MARK: :443 — ยังไม่แตะ TLS แค่แอบดู SNI แล้วตัดสินใจ
    private func handleTLS(_ conn: NWConnection) {
        readUntil(conn, cap: 8192, done: { parseSNI($0) != nil }) { buf in
            guard let head = buf else { conn.cancel(); return }
            // ไม่มี SNI (เข้าด้วย IP ตรง ๆ) ก็ยังรับไว้ แล้วให้ชั้น HTTP ตอบว่าไม่มี route
            let sni = parseSNI(head) ?? "localhost"
            let target: String
            if let route = self.config.match(sni), route.passthrough {
                target = route.to
            } else {
                target = "127.0.0.1:\(self.ensureCovered(sni))"
            }
            connect(to: target) { backend in
                guard let be = backend else { conn.cancel(); return }
                be.send(content: head, completion: .contentProcessed { _ in })
                pipe(conn, be)
            }
        }
    }

    // MARK: หลังถอด TLS แล้ว — route ตาม Host header
    private func handleDecrypted(_ conn: NWConnection) {
        readUntil(conn, done: { $0.range(of: Data("\r\n\r\n".utf8)) != nil }) { buf in
            guard let head = buf else { conn.cancel(); return }
            guard let (host, rewritten) = rewriteHead(head, proto: "https") else {
                reply(conn, "400 Bad Request", "อ่าน Host header ไม่ได้\n"); return
            }
            guard let route = self.config.match(host), !route.passthrough else {
                let known = self.config.routes.map { "  \($0.host) → \($0.to)" }.joined(separator: "\n")
                reply(conn, "502 Bad Gateway",
                      "dnsdev: ไม่มี route สำหรับ \(host)\n\nที่มีอยู่:\n\(known)\n\n"
                      + "เพิ่มด้วย: dnsdev add \(host) <port>\n")
                return
            }
            connect(to: route.to) { backend in
                guard let be = backend else {
                    reply(conn, "502 Bad Gateway",
                          "dnsdev: \(host) ชี้ไป \(route.to) แต่ต่อไม่ติด — dev server ยังไม่ขึ้น?\n")
                    return
                }
                be.send(content: rewritten, completion: .contentProcessed { _ in })
                pipe(conn, be)
            }
        }
    }

    // MARK: :80 — ดันขึ้น https ให้หมด
    private func handlePlain(_ conn: NWConnection) {
        readUntil(conn, done: { $0.range(of: Data("\r\n\r\n".utf8)) != nil }) { buf in
            guard let head = buf, let text = String(data: head, encoding: .utf8) else {
                conn.cancel(); return
            }
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let host = lines.first(where: { $0.lowercased().hasPrefix("host:") })?
                .dropFirst(5).trimmingCharacters(in: .whitespaces)
                .split(separator: ":").first.map(String.init) ?? ""
            let body = "ย้ายไป https\n".data(using: .utf8)!
            let resp = "HTTP/1.1 301 Moved Permanently\r\nLocation: https://\(host)\(path)\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: resp.data(using: .utf8)! + body,
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// แทรก X-Forwarded-* ให้ backend รู้ว่าเดิมมาเป็น https ไม่งั้น framework ที่ redirect
/// เองจะเด้งกลับเป็น http แล้ววนไม่จบ  คืน (host, head ที่แก้แล้ว)
func rewriteHead(_ data: Data, proto: String) -> (String, Data)? {
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
          let text = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard let hostLine = lines.first(where: { $0.lowercased().hasPrefix("host:") }) else { return nil }
    let host = hostLine.dropFirst(5).trimmingCharacters(in: .whitespaces)

    lines.removeAll { l in
        let k = l.lowercased()
        return k.hasPrefix("x-forwarded-proto:") || k.hasPrefix("x-forwarded-host:")
            || k.hasPrefix("x-forwarded-for:")
    }
    lines.append("X-Forwarded-Proto: \(proto)")
    lines.append("X-Forwarded-Host: \(host)")
    lines.append("X-Forwarded-For: 127.0.0.1")

    let newHead = lines.joined(separator: "\r\n") + "\r\n\r\n"
    var out = Data(newHead.utf8)
    out.append(data[sep.upperBound...])          // body ที่ติดมากับก้อนแรก ห้ามทิ้ง
    return (host.split(separator: ":").first.map(String.init) ?? host, out)
}

// ---------- main ----------
@main
struct Main {
    static func main() {
        setvbuf(stderr, nil, _IOLBF, 0)

        // --ensure-ca ให้ CLI เรียกสร้าง CA ได้โดยไม่ต้องเขียนคำสั่ง openssl ซ้ำอีกที่
        // พารามิเตอร์ของ cert อยู่ที่เดียวจบ จะได้ไม่มีวันหลุดจากกัน
        if CommandLine.arguments.contains("--ensure-ca") {
            do { try ensureCA(); print(caCert.path) } catch {
                log("สร้าง CA ไม่สำเร็จ: \(error)"); exit(1)
            }
            exit(0)
        }

        let proxy = Proxy()
        proxy.start()
        dispatchMain()
    }
}
