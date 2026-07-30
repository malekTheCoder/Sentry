import Foundation
import MacStatKit
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat
import os

/// In-app HTTP transport for MacStat's MCP tools — the LAN-reachable
/// counterpart to the local-only stdio `MacStatMCP` binary. Off by default
/// (`AppSettings.mcpRemoteAccessEnabled`); `AppDelegate` starts/stops it as
/// that setting (and `mcpRemotePort`) change.
///
/// **Why bearer-token auth is the real gate here, not network topology.**
/// Binding to all interfaces makes this reachable from anything on the same
/// LAN — a guest on the Wi-Fi, another device in the house, not just the
/// intended client. `APIKeyValidator` (`MacStatKit/MCP/APIKeyValidator.swift`)
/// is what actually decides who gets an answer. `OriginValidator` is
/// disabled in the validation pipeline below rather than configured with
/// `allowedHosts` — a bearer token the client must be handed out-of-band is
/// a stronger, more deliberate gate than an `Origin` header the client
/// controls anyway, and the MCP SDK's own `OriginValidator.disabled` exists
/// precisely for "non-localhost deployments where DNS rebinding isn't the
/// threat model" (its doc comment).
///
/// **Why every remote call still goes through `MCPXPCService`, not a
/// bespoke shortcut into `StatsCoordinator`/`PowerControlService`/etc.**
/// `start(port:serviceCaller:)` takes an injected `MCPServiceCalling` —
/// `AppDelegate` passes a `LocalXPCServiceCaller` wrapping its existing
/// `mcpXPCService` (a direct in-process call, no XPC transport; see that
/// type's doc comment for why an actual `NSXPCConnection` self-connect to
/// this process's own Mach service was tried first and failed). Either way,
/// every call flows through the exact same `MCPAccessController` per-tool
/// gating, rate limiting, and (for write tools) native confirmation
/// `NSAlert` that local calls already get — there's no shortcut that
/// bypasses any of it just because the call arrived over HTTP instead of
/// stdio.
///
/// **v1 scope:** `StatelessHTTPServerTransport` (request/response only, no
/// SSE) — a remote caller can call tools and read resources, but doesn't get
/// live `resources/updated` push notifications the way a stdio client does.
/// Hand-rolling SSE framing (chunked transfer, keep-alive, `Last-Event-ID`
/// resumability) over a bespoke NIO handler was judged more risk than this
/// feature's v1 needed; the stdio path is unaffected and keeps that
/// capability.
public final class MCPRemoteServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.malekswilam.macstat", category: "MCPRemoteServer")

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var boundPort: Int?

    public init() {}

    /// Starts listening on `port`, bound to all interfaces. No-ops if
    /// already listening on the same port; stops and restarts if the port
    /// changed. Silently refuses to start if no API key has been generated
    /// yet (see `APIKeyValidator`'s doc comment on why "no key configured"
    /// must mean "reject everything," never "accept everything") — the
    /// Settings UI is expected to generate one the first time this is
    /// enabled, but this is the last line of defense if that somehow didn't
    /// happen.
    public func start(port: Int, serviceCaller: any MCPServiceCalling) async {
        if let boundPort, boundPort == port { return }
        await stop()

        guard let apiKey = MCPRemoteAccessKey.current() else {
            Self.logger.notice("Not starting MCPRemoteServer: no API key has been generated yet.")
            return
        }

        let clientIdentity = MCPClientIdentity()
        let subscriptionPump = ResourceSubscriptionPump(xpcClient: serviceCaller, clientName: "MacStat (remote HTTP)")
        let mcpServer = await MacStatMCPServerFactory.makeServer(
            xpcClient: serviceCaller,
            clientIdentity: clientIdentity,
            subscriptionPump: subscriptionPump
        )

        let validationPipeline = StandardValidationPipeline(validators: [
            APIKeyValidator(expectedKey: apiKey),
            OriginValidator.disabled,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        let transport = StatelessHTTPServerTransport(validationPipeline: validationPipeline)

        do {
            try await mcpServer.start(transport: transport) { clientInfo, _ in
                await clientIdentity.set(clientInfo.name)
            }
        } catch {
            Self.logger.error("Failed to start MCP server for remote transport: \(error.localizedDescription, privacy: .public)")
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(MCPHTTPChannelHandler(transport: transport))
                }
            }

        do {
            let boundChannel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
            self.group = group
            self.channel = boundChannel
            self.boundPort = port
            Self.logger.notice("MCPRemoteServer listening on 0.0.0.0:\(port, privacy: .public)")
        } catch {
            Self.logger.error("Failed to bind MCPRemoteServer on port \(port, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await Self.shutdown(group)
        }
    }

    /// Idempotent — safe to call whether or not the server is currently
    /// listening (mirrors `PowerControlService.releaseAssertion()`'s own
    /// "safe to call with nothing active" convention).
    public func stop() async {
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        if let group {
            await Self.shutdown(group)
        }
        group = nil
        boundPort = nil
    }

    private static func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }
}

// MARK: - NIO ↔ MCP HTTPRequest/HTTPResponse bridge

/// Converts one HTTP/1.1 request (as decoded by NIO's
/// `configureHTTPServerPipeline`) into the MCP SDK's framework-agnostic
/// `HTTPRequest`, feeds it to the shared `StatelessHTTPServerTransport`, and
/// writes the resulting `HTTPResponse` back. One instance per connection
/// (NIO's per-channel-pipeline convention); the `transport` itself is
/// shared across every connection, matching how a single `MacStatMCP`
/// process serves one long-lived stdio session — here, potentially many
/// concurrent short-lived HTTP ones.
final class MCPHTTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let transport: StatelessHTTPServerTransport
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(transport: StatelessHTTPServerTransport) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            bodyBuffer?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else { return }
            let bodyData: Data? = bodyBuffer.flatMap { buffer -> Data? in
                var buffer = buffer
                guard buffer.readableBytes > 0 else { return nil }
                return buffer.readData(length: buffer.readableBytes)
            }
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name] = value
            }
            let mcpRequest = HTTPRequest(
                method: head.method.rawValue,
                headers: headers,
                body: bodyData,
                path: head.uri
            )
            requestHead = nil
            bodyBuffer = nil

            let channel = context.channel
            let transport = self.transport
            let promise = context.eventLoop.makePromise(of: HTTPResponse.self)
            promise.completeWithTask {
                await transport.handleRequest(mcpRequest)
            }
            promise.futureResult.whenComplete { result in
                channel.eventLoop.execute {
                    switch result {
                    case .success(let response):
                        Self.write(response: response, on: channel)
                    case .failure:
                        Self.writeInternalError(on: channel)
                    }
                }
            }
        }
    }

    private static func write(response: HTTPResponse, on channel: Channel) {
        let bodyData = response.bodyData ?? Data()
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: "\(bodyData.count)")

        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if !bodyData.isEmpty {
            var buffer = channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }

    private static func writeInternalError(on channel: Channel) {
        let head = HTTPResponseHead(version: .http1_1, status: .internalServerError)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}
