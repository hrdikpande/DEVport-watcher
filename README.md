# Ports

Ports tells developers what is running locally, why it is running, whether it is safe, and how to stop it — without leaving the menu bar.

Ports is a lightweight native macOS menu-bar app for discovering and managing
listening TCP ports.

It is designed for developers who need to quickly answer:

- Which process is using this port?
- Is the service reachable from my local network?
- Which project or tool started it?
- Can I stop it safely?

## Features

### Port monitoring

- Discovers listening TCP sockets and their owning processes.
- Displays the port, PID, executable, command line, and working directory.
- Identifies listeners exposed on all network interfaces with a `LAN` indicator.
- Distinguishes LAN-accessible services from localhost-only services.
- Refreshes automatically in the background.
- Shows the current number of developer listeners in the menu bar.
- Uses cached results so the menu opens immediately.

### Process classification

Listeners are grouped into:

- **Frontend** — Vite, Next.js, Astro, Nuxt, Webpack, Angular, Storybook,
  Expo, and other frontend tools.
- **Backend** — Node.js, Python, Ruby, PHP, Java, Go, Deno, Bun, .NET,
  FastAPI, Rails, and other backend runtimes.
- **Databases** — PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch, RabbitMQ,
  Kafka, Neo4j, and other common services.
- **Docker** — Docker-published ports and Docker engine listeners.
- **System & Apps** — macOS services, applications, and editor extensions.

The menu can be filtered to show:

- Developer listeners
- System & Apps
- All listeners

The selected filter is remembered between launches.

### Listener actions

Expand any listener to:

- View its PID and command line.
- View its network exposure.
- View its working directory.
- Open `http://localhost:<port>` in a browser.
- Reveal its working directory in Finder.
- Copy its PID to the clipboard.

### Safe process management

Processes can be stopped:

- From a listener row.
- By entering a port number.
- By entering a PID.

Stopping requires confirmation. Ports:

- Sends a graceful termination signal first.
- Escalates after approximately two seconds if the process remains alive.
- Re-checks process identity before signaling to prevent PID reuse mistakes.
- Refuses to stop the Ports app, PID 1, protected processes, or processes owned
  by another user.
- Shows warnings before stopping system or application processes.

### Docker integration

When Docker is installed, Ports:

- Detects Docker-published host ports.
- Shows the associated container name.
- Stops the container instead of directly killing the host-side process.
- Validates container names before executing Docker commands.
- Uses fixed executable paths, argument arrays, and command timeouts.
- Displays a restart hint after stopping a container.

Docker is optional. Ports continues to monitor native processes when Docker is
not installed or unavailable.

### Command-line mode

The application supports a diagnostic listing mode:

```sh
Ports --list
```

This prints a table containing:

- Port
- PID
- Category
- LAN exposure
- Process label
- Scan timing information

## Requirements

- macOS 14 or later
- Swift compiler and Apple command-line build tools for building from source
- Docker is optional

## Build and install

Clone the repository, then run:

```sh
./build.sh
```

The build script:

1. Generates the application icon if necessary.
2. Compiles the Swift source.
3. Creates `build/Ports.app`.
4. Copies the bundle metadata and icon.
5. Applies an ad-hoc hardened-runtime signature.
6. Installs the application to:

```text
~/Applications/Ports.app
```

Open the installed app from Finder or launch it from the command line:

```sh
open ~/Applications/Ports.app
```

## Usage

1. Launch **Ports**.
2. Click the Ports icon in the macOS menu bar.
3. Choose a listener category or filter.
4. Expand a listener to inspect its details.
5. Use the available actions to open, inspect, copy, or stop the service.

Keyboard shortcuts are available in the menu:

- `Command-1` — Developer
- `Command-2` — System & Apps
- `Command-3` — All
- `Command-K` — Kill by Port
- `Command-Shift-K` — Kill by PID
- `Command-Q` — Quit Ports

## Security and privacy

Ports is local-only. It does not send port or process information to a remote
service.

The application reads process and socket information from macOS system APIs. In
the current release, Docker integration invokes the Docker CLI only when Docker
is available; there are no HTTP or database protocol probes and no Docker socket
probe.

Planned probes are documented here before implementation:

| Probe | When | Where | Timeout | Access |
| --- | --- | --- | --- | --- |
| HTTP | Panel open only | Loopback only | 800 ms | Read-only |
| Database protocol | Panel open only | Loopback only | 300 ms | Read-only |
| Docker socket | Panel open only | Local Unix socket | 2 s | Read-only except explicit stop actions |

Docker CLI commands use fixed executable paths, validated arguments, minimal
environment variables, and timeouts.

## Project structure

```text
Package.swift           Swift Package Manager manifest
Sources/PortsCore/      Shared scanner, classifier, Docker, and safety logic
Sources/PortsApp/       AppKit menu-bar application
Sources/ports/           CLI listing command
Tests/PortsCoreTests/   Characterization tests and real-output fixtures
Info.plist              macOS bundle metadata
build.sh                Build, sign, and install wrapper
Scripts/build_app.sh    Application bundle build script
assets/                 Application icon
tools/                  Icon generation utility
```

## License

Ports is released under the MIT License. See [LICENSE](LICENSE).
