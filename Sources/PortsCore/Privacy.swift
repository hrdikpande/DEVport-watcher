// Every probe Ports makes, for Settings › Privacy and the README (one source of truth).
import Foundation

public struct PrivacyProbe: Sendable {
    public let name: String
    public let when: String
    public let whereTo: String
    public let timeout: String
    public let what: String
}

public let privacyProbes: [PrivacyProbe] = [
    .init(name: "HTTP probe", when: "Only while the panel is open (or with `ports list --probe`)",
          whereTo: "127.0.0.1 and ::1 only. Never servers bound only to a LAN address, never databases or tunnels",
          timeout: "0.8 s per listener, at most 4 at once, re-probed after 30 s",
          what: "Read-only: HEAD / to detect HTTP, then one GET / (first 64 KB) for status, time, Server header and <title>."),
    .init(name: "TLS hello", when: "Same as the HTTP probe, when a server doesn't answer plain HTTP",
          whereTo: "127.0.0.1 and ::1 only", timeout: "Within the same 0.8 s",
          what: "Read-only: a minimal TLS ClientHello and, for HTTPS servers, one GET /. Self-signed certificates are accepted for this probe only."),
    .init(name: "Database handshake", when: "Only while the panel is open (or with `ports list --probe`)",
          whereTo: "Loopback only, only your own listeners above port 1023 that aren't already known as databases",
          timeout: "300 ms per handshake, 0.8 s per listener",
          what: "Read-only: PostgreSQL SSLRequest, MySQL greeting, Redis PING, MongoDB hello, Memcached version, AMQP header. Never sends credentials."),
    .init(name: "Docker Engine socket", when: "Only while a container runtime's port proxy is listening: on every panel open, at most every 15 s otherwise",
          whereTo: "Local unix sockets of Docker Desktop, OrbStack, Colima, Lima, Rancher Desktop, Podman (never DOCKER_HOST=tcp://)",
          timeout: "2 s",
          what: "Read-only GET /containers/json. Containers are stopped or restarted only when you confirm it."),
    .init(name: "ngrok agent API", when: "Only while the panel is open (or with `ports list --probe`)",
          whereTo: "127.0.0.1, on the ngrok agent's own port", timeout: "0.8 s", what: "Read-only GET /api/tunnels for public URLs."),
    .init(name: "cloudflared metrics", when: "Only while the panel is open (or with `ports list --probe`)",
          whereTo: "127.0.0.1, on cloudflared's own metrics port", timeout: "0.8 s", what: "Read-only GET /quicktunnel for a quick tunnel's hostname."),
    .init(name: "Bind probe", when: "Only when you use Check Port…, Find Free Port…, `ports preflight` or `ports next-free`",
          whereTo: "This Mac: 127.0.0.1, ::1, 0.0.0.0", timeout: "Immediate",
          what: "Binds the port without listening and closes it at once. No traffic is sent."),
    .init(name: "Local commands", when: "launchctl list while the panel is open; brew services / launchctl bootout / pm2 / docker only when you confirm a stop",
          whereTo: "This Mac (fixed paths, no shell, minimal environment)", timeout: "2–30 s",
          what: "Read-only except the stop you confirmed."),
    .init(name: "Update check (off by default)", when: "Once a day, only if you turn it on in Settings › General",
          whereTo: "api.github.com (the project's latest release)", timeout: "10 s",
          what: "The only request Ports ever makes to the internet. Nothing about your Mac is sent."),
]
