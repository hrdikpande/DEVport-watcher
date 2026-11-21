// The ONLY place PortsCore launches child processes: fixed absolute path, argv array (no shell),
// minimal environment, timeout.
import Foundation

/// `pathPrefix`: extra folders searched first (e.g. the tool's own bin folder, so a node-based CLI finds node).
public func run(_ path: String, _ args: [String], timeout: TimeInterval = 3, pathPrefix: [String] = []) -> (out: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args                                            // argv array: no shell, no injection
    p.environment = ["HOME": home, "PATH": (pathPrefix + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return ("", false) }
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .utility).async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 1)
        return ("Timed out after \(Int(timeout)) s", false)
    }
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus == 0)
}
