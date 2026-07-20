import Foundation
import Network

/// A tiny loopback-only HTTP/1.1 server (Network framework). Used to expose a Prometheus
/// `/metrics` endpoint and a small local REST API. Binds to `127.0.0.1` so it is never
/// reachable off-device.
public final class LocalHTTPServer: @unchecked Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let contentType: String
        public let body: String
        public init(status: Int = 200,
                    contentType: String = "text/plain; version=0.0.4; charset=utf-8",
                    body: String) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
        public static func json(_ s: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json; charset=utf-8", body: s)
        }
        public static func notFound() -> Response {
            Response(status: 404, body: "not found\n")
        }
    }

    private let port: NWEndpoint.Port
    private let handler: @Sendable (_ path: String) -> Response
    private let queue = DispatchQueue(label: "com.jhkoo.claude-usage-monitor.http")
    private var listener: NWListener?

    public init(port: UInt16, handler: @escaping @Sendable (_ path: String) -> Response) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 9090
        self.handler = handler
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Force the local bind address to loopback — not reachable off the machine.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.parsePath(request)
            let response = self.handler(path)
            connection.send(content: Self.serialize(response),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    public static func parsePath(_ request: String) -> String {
        guard let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else {
            return "/"
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        let target = String(parts[1])
        return String(target.split(separator: "?").first ?? Substring(target))
    }

    static func serialize(_ r: Response) -> Data {
        let body = Data(r.body.utf8)
        let head = """
        HTTP/1.1 \(r.status) \(reason(r.status))\r
        Content-Type: \(r.contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
