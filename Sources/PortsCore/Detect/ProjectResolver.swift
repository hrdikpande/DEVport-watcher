// Phase 2: project root from manifests (incl. monorepos) and git branch read straight from .git (no git process).
import Foundation

public struct Project: Equatable, Sendable {
    public let root: String          // folder holding the nearest manifest (or .git)
    public let name: String          // manifest name, else folder name
    public let repo: String?         // enclosing repo/workspace name when `root` is a package inside it
    public let repoRoot: String      // where .git lives (== root when not in a monorepo)
    public var branch: String?
    public var dependencies: [String]  // package.json dependencies + devDependencies (names only)

    public init(root: String, name: String, repo: String? = nil, repoRoot: String? = nil, branch: String? = nil,
                dependencies: [String] = []) {
        self.root = root; self.name = name; self.repo = repo; self.repoRoot = repoRoot ?? root; self.branch = branch
        self.dependencies = dependencies
    }

    /// "web", "shop › web", "shop › web · main".
    public var display: String { repo.map { "\($0) › \(name)" } ?? name }
    public var displayWithBranch: String { branch.map { "\(display) · \($0)" } ?? display }
}

/// Finds the project a directory belongs to. Results are cached per directory; thread-safe.
public final class ProjectResolver: @unchecked Sendable {
    public static let markers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Gemfile",
                                 "composer.json", "pom.xml", "build.gradle", "build.gradle.kts", "deno.json",
                                 "deno.jsonc", "bun.lockb"]
    /// Files that make a folder a monorepo/workspace root even without .git.
    static let workspaceMarkers = ["pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json", "go.work"]

    private let home: String
    private let fm = FileManager.default
    private let lock = NSLock()
    private var cache: [String: Project?] = [:]

    public init(home: String = PortsCore.home) { self.home = home }

    /// Prefer the script's own package when it sits deeper inside the cwd's project (monorepo app run
    /// from the repo root); never resolve through node_modules or a virtualenv.
    public func resolve(cwd: String, script: String?) -> Project? {
        let fromCwd = cwd.isEmpty ? nil : resolve(dir: cwd)
        guard let script, !script.isEmpty else { return fromCwd }
        let path = script.hasPrefix("/") ? script : (cwd as NSString).appendingPathComponent(script)
        let dir = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
        let vendored = ["/node_modules/", "/site-packages/", "/dist-packages/", "/.venv/", "/vendor/"]
        guard !vendored.contains(where: { (dir + "/").contains($0) }), let fromScript = resolve(dir: dir) else { return fromCwd }
        guard let c = fromCwd else { return fromScript }
        return fromScript.root.hasPrefix(c.root + "/") ? fromScript : c
    }

    public func resolve(dir: String) -> Project? {
        let dir = (dir as NSString).standardizingPath
        lock.lock()
        if let hit = cache[dir] { lock.unlock(); return hit }
        lock.unlock()
        let p = lookUp(dir)
        lock.lock(); cache[dir] = p; lock.unlock()
        return p
    }

    /// `/` and the home folder itself are never projects (a dotfiles repo in ~ must not claim everything).
    func isCandidate(_ dir: String) -> Bool { dir != "/" && !dir.isEmpty && dir != home }

    func lookUp(_ start: String) -> Project? {
        var dir = start, depth = 0
        var package: String?
        while isCandidate(dir), depth < 64 {
            if package == nil, Self.markers.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) {
                package = dir
                if fm.fileExists(atPath: dir + "/.git") { break }
            } else if package != nil, fm.fileExists(atPath: dir + "/.git") || isWorkspaceRoot(dir) {
                let repo = dir
                return Project(root: package!, name: manifestName(package!), repo: manifestName(repo), repoRoot: repo,
                               dependencies: nodeDependencies(package!))
            }
            dir = (dir as NSString).deletingLastPathComponent
            depth += 1
        }
        guard let package else { return nil }
        return Project(root: package, name: manifestName(package), dependencies: nodeDependencies(package))
    }

    /// Declared npm dependencies of the package (framework hints such as express, fastify, @nestjs/core).
    func nodeDependencies(_ dir: String) -> [String] {
        guard let json = readJSON(dir + "/package.json") else { return [] }
        let keys = ["dependencies", "devDependencies"].flatMap { (json[$0] as? [String: Any])?.keys.map { $0 } ?? [] }
        return Array(Set(keys)).sorted()
    }

    func isWorkspaceRoot(_ dir: String) -> Bool {
        if Self.workspaceMarkers.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) { return true }
        if let json = readJSON(dir + "/package.json"), json["workspaces"] != nil { return true }
        if let cargo = read(dir + "/Cargo.toml"), cargo.contains("[workspace]") { return true }
        return false
    }

    /// The manifest's own project name, else the folder name.
    public func manifestName(_ dir: String) -> String {
        let folder = (dir as NSString).lastPathComponent
        for file in ["package.json", "deno.json", "composer.json"] {
            if let name = readJSON(dir + "/" + file)?["name"] as? String, !name.isEmpty {
                return file == "composer.json" ? String(name.split(separator: "/").last ?? Substring(name)) : name
            }
        }
        if let toml = read(dir + "/pyproject.toml"),
           let n = tomlValue(toml, key: "name", sections: ["project", "tool.poetry"]) { return n }
        if let toml = read(dir + "/Cargo.toml"), let n = tomlValue(toml, key: "name", sections: ["package"]) { return n }
        if let mod = read(dir + "/go.mod"),
           let line = mod.split(separator: "\n").first(where: { $0.hasPrefix("module ") }) {
            let path = line.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
            if let last = path.split(separator: "/").last { return String(last) }
        }
        if let pom = read(dir + "/pom.xml"), let n = pomArtifactId(pom) { return n }
        for settings in ["settings.gradle", "settings.gradle.kts"] {
            if let s = read(dir + "/" + settings),
               let m = s.range(of: #"rootProject\.name\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                return String(s[m]).components(separatedBy: CharacterSet(charactersIn: "\"'"))[1]
            }
        }
        return folder
    }

    func read(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path), data.count < 1_000_000 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func readJSON(_ path: String) -> [String: Any]? {
        guard let data = fm.contents(atPath: path), data.count < 1_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any]
    }
}

/// `key = "value"` inside one of `sections` of a TOML file (enough for name lookup; not a TOML parser).
func tomlValue(_ toml: String, key: String, sections: [String]) -> String? {
    var section = ""
    for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
        guard sections.contains(section), line.hasPrefix(key) else { continue }
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { continue }
        let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let q = value.first, q == "\"" || q == "'" else { continue }
        let inner = value.dropFirst().prefix { $0 != q }
        if !inner.isEmpty { return String(inner) }
    }
    return nil
}

/// The project's own `<artifactId>`, skipping the one inside `<parent>`.
func pomArtifactId(_ pom: String) -> String? {
    var text = pom
    if let p = text.range(of: "<parent>"), let e = text.range(of: "</parent>", range: p.upperBound..<text.endIndex) {
        text.removeSubrange(p.lowerBound..<e.upperBound)
    }
    guard let s = text.range(of: "<artifactId>"), let e = text.range(of: "</artifactId>", range: s.upperBound..<text.endIndex)
    else { return nil }
    let id = text[s.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : id
}

// MARK: - Git

public enum GitInfo {
    /// Current branch of the repo at `root`, read from `.git/HEAD`. Worktrees and submodules use a `.git`
    /// file (`gitdir: <path>`); a detached HEAD shows the short SHA. nil when not a git checkout.
    public static func branch(repoRoot root: String) -> String? {
        let fm = FileManager.default
        let dotGit = root + "/.git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        var gitDir = dotGit
        if !isDir.boolValue {
            guard let text = fm.contents(atPath: dotGit).map({ String(decoding: $0, as: UTF8.self) }),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = path.hasPrefix("/") ? path : ((root as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        guard let head = fm.contents(atPath: gitDir + "/HEAD").map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        return parseHead(head)
    }

    /// "ref: refs/heads/feature/x" -> "feature/x"; a bare SHA -> its first 7 characters.
    public static func parseHead(_ head: String) -> String? {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("ref:") {
            let ref = h.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : (ref.isEmpty ? nil : ref)
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard h.count >= 40, h.unicodeScalars.allSatisfy(hex.contains) else { return nil }
        return String(h.prefix(7))
    }
}

/// The script file an interpreter runs (`node server.js`, `python3 app/main.py`), for project lookup.
/// nil for `python -m module`, inline code, or a non-interpreter.
public func scriptArgument(exe: String, argv: [String]) -> String? {
    let exeName = basename(exe).lowercased()
    guard let first = argv.first else { return nil }
    let a0 = basename(first).lowercased()
    guard isInterpreter(a0) || isInterpreter(exeName), !["java"].contains(a0), exeName != "java" else { return nil }
    var rest = argv.dropFirst()
    if ["bun", "deno"].contains(a0) || ["bun", "deno"].contains(exeName), rest.first == "run" { rest = rest.dropFirst() }
    if rest.contains("-m") { return nil }
    return firstOperand(rest)
}
