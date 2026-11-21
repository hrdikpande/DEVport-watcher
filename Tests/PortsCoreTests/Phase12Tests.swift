import Foundation
import Testing
@testable import PortsCore

func repoFile(_ path: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

@Suite("Phase 12 · Final safety review")
struct SafetyReview12 {
    @Test("Probe sockets refuse anything but loopback")
    func loopbackOnly() throws {
        let s = try TestListener()
        s.serve(Array("+PONG\r\n".utf8))
        let far = Date().addingTimeInterval(5)
        #expect(exchange(host: "127.0.0.1", port: s.port, payload: redisPing, deadline: far) != nil)
        #expect(exchange(host: "192.168.1.20", port: s.port, payload: redisPing, deadline: far) == nil)
        #expect(exchange(host: "0.0.0.0", port: s.port, payload: redisPing, deadline: far) == nil)
        #expect(connectLoopback("10.0.0.1", port: s.port, deadline: far) == nil)
    }

    @Test("MCP stop and the update check are off by default")
    func defaultsOff() {
        let s = Settings()
        #expect(!s.mcpEnabled && !s.mcpAllowStop && !s.updateCheck)
    }
}

@Suite("Phase 12 · Distribution and docs")
struct DistributionTests12 {
    @Test("README opens with the product line and has privacy, safety, CLI and MCP sections")
    func readme() throws {
        let r = try repoFile("README.md")
        #expect(r.hasPrefix("# Ports\n\nPorts tells developers what is running locally, why it is running, whether it is safe, and how to stop it — without leaving the menu bar."))
        for section in ["## Install", "## Safety model", "## Privacy", "## Command line", "## MCP server", "## How it compares"] {
            #expect(r.contains(section), "\(section)")
        }
        for p in privacyProbes { #expect(r.contains("| \(p.name) |"), "README privacy table lacks \(p.name)") }
        #expect(r.contains("`stop_port` is off by default"))
        #expect(r.contains("`2` refused by the safety rules"))
    }

    @Test("Release script builds unsigned without secrets and labels it; workflow runs on tags")
    func release() throws {
        let s = try repoFile("Scripts/release.sh")
        #expect(s.contains("-unsigned") && s.contains("**Unsigned build**") && s.contains("notarytool submit") && s.contains("stapler staple"))
        #expect(s.contains("SHA256SUMS.txt") && s.contains("hdiutil create"))
        let w = try repoFile(".github/workflows/release.yml")
        #expect(w.contains("tags: [\"v*\"]") && w.contains("./Scripts/release.sh") && !w.contains("setup-swift"))
        #expect(w.contains("HAS_CERT") && w.contains("gh release create"))
        let b = try repoFile("Scripts/build_app.sh")
        #expect(b.contains("DEVELOPER_ID_APPLICATION") && b.contains("--timestamp") && b.contains("--no-install"))
    }

    @Test("Homebrew cask and source formula templates")
    func homebrew() throws {
        let c = try repoFile("packaging/homebrew-tap/Casks/ports.rb")
        for part in ["auto_updates false", "depends_on macos: \">= :sonoma\"", "app \"Ports.app\"", "binary ", "zap trash:", "livecheck do",
                     "Contents/Helpers/ports"] {
            #expect(c.contains(part), "\(part)")
        }
        let f = try repoFile("packaging/homebrew-tap/Formula/ports.rb")
        #expect(f.contains("swift\", \"build\"") && f.contains("depends_on xcode:") && f.contains("test do"))
    }

    @Test("Every feature checklist item is ticked or says why not")
    func features() throws {
        let lines = try repoFile("docs/FEATURES.md").split(separator: "\n").filter { $0.hasPrefix("- [ ]") }
        for l in lines { #expect(l.contains("needs the owner") || l.contains("non-goal"), "\(l)") }
    }
}

@Suite("Phase 12 · Closed-panel scan cost")
struct QuietScanTests12 {
    @Test("Quiet PIDs are skipped until their recheck time; listeners and exited PIDs are never skipped")
    func quiet() {
        let c = ProcessCache(load: { _ in ("/bin/demo", ["demo"], "/tmp") })
        let t0 = Date(timeIntervalSince1970: 1_000)
        c.markQuiet(10, now: t0)
        c.markQuiet(11, now: t0)
        c.markListening(11)
        #expect(c.quietPIDs(olderThan: 30, live: [10, 11], now: t0.addingTimeInterval(10)) == [10])
        #expect(c.quietPIDs(olderThan: 30, live: [10, 11], now: t0.addingTimeInterval(31)).isEmpty)       // due for a recheck
        #expect(c.quietPIDs(olderThan: 0, live: [10, 11], now: t0).isEmpty)                                // open panel / CLI: all
        #expect(c.quietPIDs(olderThan: 30, live: [11], now: t0.addingTimeInterval(1)).isEmpty)            // 10 exited: forgotten
    }

    @Test("A process marked quiet is skipped until its recheck; a full scan (open panel, CLI) always finds it")
    func latency() throws {
        let s = try TestListener()
        let cache = ProcessCache()
        cache.markQuiet(getpid())                       // as if this process listened on nothing at the last check
        #expect(!scan(docker: [:], cache: cache, quietRecheck: 30).contains { $0.pid == getpid() && $0.port == s.port })
        #expect(scan(docker: [:], cache: cache, quietRecheck: 0).contains { $0.pid == getpid() && $0.port == s.port })
        // Once found listening it is never skipped again.
        #expect(scan(docker: [:], cache: cache, quietRecheck: 30).contains { $0.pid == getpid() && $0.port == s.port })
    }
}

@Suite("Phase 12 · Container back-off")
struct ContainerBackoffTests12 {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test("When no engine answers, closed-panel scans wait 10 minutes before asking (and spawning the CLI) again")
    func backoff() {
        let calls = Calls()
        let dir = ContainerDirectory(locate: { [] }, cli: { calls.bump(); return nil })
        let proxy = Listener(port: 5432, pid: 9, start: 1, uid: getuid(), exposed: false, exe: "/opt/homebrew/bin/gvproxy", command: "gvproxy", cwd: "/")
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(dir.current(listeners: [proxy], maxAge: 60, now: t0)?.reachable == false)
        _ = dir.current(listeners: [proxy], maxAge: 60, now: t0.addingTimeInterval(120))
        #expect(calls.value == 1)                                         // backed off
        _ = dir.current(listeners: [proxy], maxAge: 60, now: t0.addingTimeInterval(601))
        #expect(calls.value == 2)
        _ = dir.current(listeners: [proxy], maxAge: 0, now: t0.addingTimeInterval(602))
        #expect(calls.value == 3)                                         // open panel: always asks
    }
}
