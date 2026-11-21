// Phase 4: who started it — the first meaningful ancestor in the launcher chain.
import Foundation

public enum StarterKind: String, Sendable, Codable {
    case agent, editor, terminal, multiplexer, supervisor, unknown
    public var title: String {
        ["agent": "Coding agent", "editor": "Editor", "terminal": "Terminal", "multiplexer": "Terminal multiplexer",
         "supervisor": "Supervisor", "unknown": "Unknown"][rawValue]!
    }
}

public struct Starter: Equatable, Sendable {
    public let kind: StarterKind
    public let name: String         // "Claude Code", "Visual Studio Code", "iTerm2", "launchd job", "unknown"
    public let pid: pid_t?          // nil when nothing in the chain matched
}

struct StarterRule: Sendable {
    let kind: StarterKind
    let name: String
    let commands: [String]          // argv0 / process name, lowercased; exact or "name-…"/"name."
    let apps: [String]              // .app bundle names (from the executable path)
    init(_ kind: StarterKind, _ name: String, commands: [String] = [], apps: [String] = []) {
        self.kind = kind; self.name = name; self.commands = commands; self.apps = apps
    }
}

/// Data-driven: first match wins, so agents precede the editors they run inside.
let starterRules: [StarterRule] = [
    .init(.agent, "Claude Code", commands: ["claude"]),
    .init(.agent, "Cursor agent", commands: ["cursor-agent"]),
    .init(.agent, "Codex CLI", commands: ["codex"]),
    .init(.agent, "Gemini CLI", commands: ["gemini"]),
    .init(.agent, "Aider", commands: ["aider"]),
    .init(.agent, "Antigravity", commands: ["agy", "antigravity"], apps: ["Antigravity"]),
    .init(.agent, "Windsurf", commands: ["windsurf"], apps: ["Windsurf"]),
    .init(.agent, "Copilot CLI", commands: ["copilot", "github-copilot-cli"]),
    .init(.agent, "OpenCode", commands: ["opencode"]),
    .init(.agent, "Kiro", commands: ["kiro"], apps: ["Kiro"]),
    .init(.editor, "Visual Studio Code", apps: ["Visual Studio Code", "Visual Studio Code - Insiders", "VSCodium"]),
    .init(.editor, "Cursor", apps: ["Cursor"]),
    .init(.editor, "Zed", commands: ["zed"], apps: ["Zed", "Zed Preview"]),
    .init(.editor, "JetBrains IDE", apps: ["IntelliJ IDEA", "IntelliJ IDEA CE", "IntelliJ IDEA Ultimate", "PyCharm",
                                            "PyCharm CE", "WebStorm", "GoLand", "PhpStorm", "RubyMine", "CLion", "Rider",
                                            "DataGrip", "RustRover", "Fleet", "Android Studio", "Aqua"]),
    .init(.editor, "Xcode", apps: ["Xcode"]),
    .init(.editor, "Nova", apps: ["Nova"]),
    .init(.terminal, "Terminal", apps: ["Terminal"]),
    .init(.terminal, "iTerm2", apps: ["iTerm", "iTerm2"]),
    .init(.terminal, "Warp", apps: ["Warp"]),
    .init(.terminal, "Ghostty", apps: ["Ghostty"]),
    .init(.terminal, "kitty", commands: ["kitty"], apps: ["kitty"]),
    .init(.terminal, "WezTerm", commands: ["wezterm-gui"], apps: ["WezTerm"]),
    .init(.terminal, "Alacritty", commands: ["alacritty"], apps: ["Alacritty"]),
    .init(.multiplexer, "tmux", commands: ["tmux"]),
    .init(.multiplexer, "screen", commands: ["screen"]),
    .init(.supervisor, "pm2", commands: ["pm2"]),
    .init(.supervisor, "nodemon", commands: ["nodemon"]),
]

func matchStarter(_ a: Ancestor) -> StarterRule? {
    let cmd = a.command.lowercased(), name = a.name.lowercased()
    let app = appBundle(of: a.exe).map { basename(String($0.dropLast(4))) }
    return starterRules.first { r in
        r.commands.contains { nameMatches(cmd, $0) || nameMatches(name, $0) || name.hasPrefix($0 + " ") }
            || (app.map(r.apps.contains) ?? false)
    }
}

/// Walk parent → … and tag the first ancestor a rule recognises; launchd itself means "launchd job"
/// only when `isLaunchdJob` (otherwise the process was reparented: unknown).
public func starter(of chain: [Ancestor], isLaunchdJob: Bool) -> Starter {
    for a in chain {
        if a.pid == 1 { break }
        if let r = matchStarter(a) { return Starter(kind: r.kind, name: r.name, pid: a.pid) }
    }
    if isLaunchdJob { return Starter(kind: .supervisor, name: "launchd job", pid: 1) }
    return Starter(kind: .unknown, name: "unknown", pid: nil)
}
