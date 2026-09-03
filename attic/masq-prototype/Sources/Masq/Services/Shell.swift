import Foundation

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var ok: Bool { status == 0 }
    var output: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return [o, e].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum Shell {
    /// รันคำสั่งตรง ๆ ไม่ผ่าน shell เลยไม่ต้องกังวลเรื่อง quoting
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 15) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do { try p.run() } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        // อ่านคู่ขนานกับที่ process ยังเขียนอยู่ ไม่งั้น pipe เต็มแล้ว deadlock
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData = $0 }), (err, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
            group.enter()
            DispatchQueue.global().async {
                sink((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
            return CommandResult(status: -2, stdout: "", stderr: "หมดเวลา (\(Int(timeout))s)")
        }
        p.waitUntilExit()
        group.wait()

        return CommandResult(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
