import Foundation
import PortsCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments == ["list"] || arguments == ["--list"] {
    for listener in scanWithContainers() { print(listRow(listener)) }
    exit(0)
}

fputs("Usage: ports [list]\n", stderr)
exit(64)
