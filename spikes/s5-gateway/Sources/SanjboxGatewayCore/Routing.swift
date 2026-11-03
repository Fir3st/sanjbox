import Foundation

public struct SSEEvent: Sendable {
    public let data: String
    public let event: String?
    public let id: String?

    public init(data: String, event: String? = nil, id: String? = nil) {
        self.data = data
        self.event = event
        self.id = id
    }

    /// Encode data as SSE lines; metadata cannot inject lines or chunk framing.
    public func encoded(maximumBytes: Int = 65_536) throws -> Data {
        guard [event, id].compactMap({ $0 }).allSatisfy({
            !$0.contains("\r") && !$0.contains("\n") && !$0.contains("\0")
        }) else { throw HTTPFailure.malformed }
        // Check before splitting/encoding so a handler cannot allocate an unbounded event.
        guard data.utf8.count <= maximumBytes,
              (event?.utf8.count ?? 0) <= maximumBytes,
              (id?.utf8.count ?? 0) <= maximumBytes else { throw HTTPFailure.tooLarge }
        var text = ""
        if let event { text += "event: \(event)\n" }
        if let id { text += "id: \(id)\n" }
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            text += "data: \(line)\n"
        }
        text += "\n"
        let result = Data(text.utf8)
        guard result.count <= maximumBytes else { throw HTTPFailure.tooLarge }
        return result
    }
}

/// A producer awaits each emit, giving the transport backpressure. Producers must
/// propagate cancellation and must not create unbounded background tasks/buffers.
public typealias SSEProducer = @Sendable (@escaping @Sendable (SSEEvent) async throws -> Void) async throws -> Void
public enum GatewayReply: Sendable {
    case response(HTTPResponse)
    case events(SSEProducer)
}

public struct TypedRoute: Sendable {
    public let mount: String
    public let methods: Set<String>
    public let handle: @Sendable (HTTPRequest) async throws -> GatewayReply

    public init(mount: String, methods: Set<String>,
                handle: @escaping @Sendable (HTTPRequest) async throws -> GatewayReply) {
        self.mount = mount
        self.methods = methods
        self.handle = handle
    }
}

public enum RouteFailure: Error { case invalidMount, duplicateMount, invalidMethod }

/// Mounts are exact, single-segment namespaces. There is no catch-all proxy or
/// client-controlled upstream selection. WP1.D2/D3 own operation/artefact policy.
public struct TypedRouter: Sendable {
    private let routes: [TypedRoute]

    public init(routes: [TypedRoute]) throws {
        var mounts = Set<String>()
        for route in routes {
            guard route.mount.first == "/", route.mount.count > 1,
                  route.mount.dropFirst().utf8.allSatisfy({
                      (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                  }) else { throw RouteFailure.invalidMount }
            guard mounts.insert(route.mount).inserted else { throw RouteFailure.duplicateMount }
            guard !route.methods.isEmpty, route.methods.isSubset(of: ["GET", "POST"]) else {
                throw RouteFailure.invalidMethod
            }
        }
        self.routes = routes
    }

    public func reply(to request: HTTPRequest) async throws -> GatewayReply {
        // Default deny. Real client auth will need a dedicated brokered contract;
        // callers cannot accidentally relay credentials through a typed handler.
        let forbidden = ["authorization", "proxy-authorization", "cookie", "x-api-key", "api-key"]
        guard forbidden.allSatisfy({ request.headers[$0] == nil }),
              ["GET", "POST"].contains(request.method) else {
            return .response(.error(403))
        }
        guard let route = routes.first(where: {
            request.path == $0.mount || request.path.hasPrefix($0.mount + "/")
        }) else { return .response(.error(404)) }
        guard route.methods.contains(request.method) else { return .response(.error(403)) }
        return try await route.handle(request)
    }
}
