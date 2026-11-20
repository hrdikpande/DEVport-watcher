import Foundation
import PortsCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments == ["list"] || arguments == ["--list"] {
    let map = dockerPath == nil ? [:] : dockerPorts()
    for listener in scan(docker: map) {
        print(
            ":\(listener.port)".padding(toLength: 7, withPad: " ", startingAt: 0),
            "\(listener.pid)".padding(toLength: 7, withPad: " ", startingAt: 0),
            listener.kind.title.padding(toLength: 14, withPad: " ", startingAt: 0),
            (listener.exposed ? "LAN " : "    ") + listener.label
        )
    }
    exit(0)
}

fputs("Usage: ports [list]\n", stderr)
exit(64)
