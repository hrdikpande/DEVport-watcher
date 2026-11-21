// Phase 3: port → likely owner → explanation → how to free it.
import Foundation

public struct KnownPort: Equatable, Sendable {
    public let owner: String
    public let explanation: String
    public let howToFree: String?
}

extension KnownPorts {
    static func entry(_ owner: String, _ explanation: String, free: String? = nil) -> KnownPort {
        KnownPort(owner: owner, explanation: explanation, howToFree: free)
    }

    public static let table: [Int: KnownPort] = [
        5000: entry("AirPlay Receiver (ControlCenter)", "macOS listens here for AirPlay; Flask's default port collides with it.",
                    free: "Turn off System Settings › General › \(airPlayPane()) › AirPlay Receiver."),
        7000: entry("AirPlay Receiver (ControlCenter)", "macOS listens here for AirPlay.",
                    free: "Turn off System Settings › General › \(airPlayPane()) › AirPlay Receiver."),
        3000: entry("Dev server default", "Default for Next.js, Rails, Express, Grafana and many others.",
                    free: "Stop the server that owns it, or start yours with another port."),
        5173: entry("Vite default", "Vite's dev server; the next free port is used if it's taken."),
        8080: entry("HTTP alternate", "Common default for Tomcat, webpack, proxies and many dev servers."),
        8000: entry("Python dev default", "Default for Django runserver, `python -m http.server` and FastAPI."),
        5432: entry("PostgreSQL", "PostgreSQL's default port.", free: "Stop the database cleanly (brew services, Postgres.app or its container)."),
        3306: entry("MySQL / MariaDB", "MySQL's default port.", free: "Stop the database cleanly (brew services or its container)."),
        6379: entry("Redis / Valkey", "Redis's default port.", free: "Stop Redis cleanly (brew services or its container)."),
        27017: entry("MongoDB", "MongoDB's default port.", free: "Stop mongod cleanly (brew services or its container)."),
        9200: entry("Elasticsearch / OpenSearch", "Search engine HTTP API."),
        5672: entry("RabbitMQ (AMQP)", "RabbitMQ's message port."),
        9092: entry("Kafka", "Kafka broker port."),
        11211: entry("Memcached", "Memcached's default port."),
        1433: entry("SQL Server", "Microsoft SQL Server, usually in a container."),
        8123: entry("ClickHouse HTTP", "ClickHouse's HTTP interface."),
        9000: entry("MinIO / PHP-FPM / ClickHouse", "MinIO's API, PHP-FPM and ClickHouse's native protocol all default here."),
        4040: entry("ngrok inspector", "The ngrok agent's local API and web inspector.", free: "Stop the ngrok agent."),
        631: entry("CUPS printing", "macOS's print system (cupsd). Leave it running."),
        88: entry("Kerberos", "macOS's built-in Kerberos service. Leave it running."),
        445: entry("SMB file sharing", "macOS File Sharing.", free: "Turn off System Settings › General › Sharing › File Sharing."),
        548: entry("AFP file sharing", "Legacy Apple file sharing."),
        2375: entry("Docker API (unencrypted)", "Docker Engine API over TCP. Anyone who can reach it controls Docker."),
        2376: entry("Docker API (TLS)", "Docker Engine API over TCP with TLS."),
        6443: entry("Kubernetes API", "Local Kubernetes (Docker Desktop, OrbStack, kind, k3d)."),
    ]

    /// What is known about a port, including the ephemeral range.
    public static func info(port: Int) -> KnownPort? {
        if let k = table[port] { return k }
        if port >= 49152 {
            return entry("Ephemeral port", "macOS hands ports from 49152 up to outgoing connections and to servers that ask for any free port.")
        }
        return nil
    }
}
