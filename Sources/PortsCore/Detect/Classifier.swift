import Darwin
import Foundation

// MARK: - Classification (edit these lists to teach it about your tools)

let interpreters: Set = ["node", "ruby", "bun", "deno", "php", "perl", "java"]     // + python*
let npxLike: Set = ["npx", "bunx", "pnpx"]                                         // <runner> <tool>
let runnerSubcommands = ["npm": ["exec"], "pnpm": ["exec", "dlx"], "yarn": ["exec", "dlx"], "bun": ["x"],
                         "uv": ["run"], "poetry": ["run"], "pipenv": ["run"]]       // <runner> <sub> <tool>
let noScriptFlags: Set = ["-c", "-e", "--eval", "-p", "--print"]                   // inline code follows
let valueFlags: Set = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-W", "-X",
                       "-cp", "-classpath", "--class-path", "-p", "--module-path",
                       "--add-opens", "--add-exports", "--add-modules", "--add-reads"]   // java
let erlangVMs: Set = ["beam.smp", "beam", "erl", "erlexec"]

func isInterpreter(_ name: String) -> Bool { interpreters.contains(name) || name.hasPrefix("python") }

/// First operand that is not a flag (or a flag's value); nil if inline code is run instead.
func firstOperand(_ args: ArraySlice<String>) -> String? {
    var i = args.startIndex
    while i < args.endIndex {
        let a = args[i]
        if noScriptFlags.contains(a) { return nil }
        if valueFlags.contains(a) { i += 2; continue }
        if !a.hasPrefix("-") { return a }
        i += 1
    }
    return nil
}

/// "vite@5" -> "vite", "@scope/pkg@1" -> "pkg"
func packageName(_ s: String) -> String {
    var n = s.hasPrefix("@") ? String(s.split(separator: "/").dropFirst().first ?? "") : s
    if let at = n.firstIndex(of: "@") { n = String(n[..<at]) }
    return n
}

/// A script path names the tool only through node_modules (or its own file name) — never its folders.
func scriptName(_ path: String) -> String {
    if let r = path.range(of: "node_modules/.bin/", options: .backwards) {
        return String(path[r.upperBound...].split(separator: "/").first ?? "")
    }
    if let r = path.range(of: "node_modules/", options: .backwards) {
        let parts = path[r.upperBound...].split(separator: "/").map(String.init)
        if let first = parts.first { return first.hasPrefix("@") && parts.count > 1 ? parts[1] : first }
    }
    return basename(path)
}

/// What the process *is*: exe basename, argv[0], and the tool/script/module it runs.
/// Directory names in paths are deliberately ignored ("~/work/astro-dashboard/app.py" is not Astro).
func identityNames(exe: String, argv: [String]) -> [String] {
    let exeName = basename(exe).lowercased()
    var names = [exeName]
    guard let first = argv.first else { return names }
    let a0 = basename(first.split(separator: " ").first.map(String.init) ?? first).lowercased()
    names.append(a0)
    let rest = argv.dropFirst()

    if npxLike.contains(a0) {
        if let t = firstOperand(rest) { names.append(packageName(t)) }
    } else if let subs = runnerSubcommands[a0], let sub = rest.first, subs.contains(sub) {
        if let t = firstOperand(rest.dropFirst()) { names.append(packageName(t)) }
    } else if erlangVMs.contains(a0) || erlangVMs.contains(exeName) {
        // The Erlang VM runs RabbitMQ and CouchDB: the app is named by `-s/-run <app>`,
        // `-progname <name>` or the `-boot <release>` file, never by the install folder.
        for (flag, value) in zip(rest, rest.dropFirst()) where ["-s", "-run", "-progname", "-boot"].contains(flag) {
            names.append(basename(value))
        }
        if names.contains(where: { $0.lowercased().hasPrefix("rabbit") }) || rest.contains(where: { $0.hasPrefix("-rabbit") }) {
            names.append("rabbitmq")
        }
    } else if isInterpreter(a0) || isInterpreter(exeName) {
        let runner = isInterpreter(a0) ? a0 : exeName
        if runner.hasPrefix("python"), let m = rest.firstIndex(of: "-m"), m + 1 < rest.endIndex {
            names.append(rest[m + 1])                                   // python -m uvicorn
        } else if runner == "java" {
            if let j = rest.firstIndex(of: "-jar"), j + 1 < rest.endIndex { names.append(basename(rest[j + 1])) }
            else if let main = firstOperand(rest) {
                names += main.split(separator: ".").map(String.init)      // org.neo4j.server.… -> neo4j
            }
        } else {
            let args = (["bun", "deno"].contains(runner) && rest.first == "run") ? rest.dropFirst() : rest
            if let script = firstOperand(args) { names.append(scriptName(script)) }
        }
    }
    return names.map { $0.lowercased() }.filter { !$0.isEmpty }
}
