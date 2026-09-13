import Foundation
import Network
import Testing
@testable import Web

/// These tests use real loopback sockets and the production URLSession transport.
/// All credentials are synthetic; no Keychain or external server is involved.
@Suite(.serialized)
@MainActor
struct CompatibleAPITransportTests {
    @Test func actualTransportDoesNotForwardCredentialsOn307Or308() async throws {
        for status in [307, 308] {
            let destination = try await CompatibleHTTPFixture.start(response: .complete("{}"))
            defer { destination.stop() }
            var redirected = URLComponents(url: destination.baseURL, resolvingAgainstBaseURL: false)!
            redirected.host = "localhost"
            let source = try await CompatibleHTTPFixture.start(response: .init(
                status: status, headers: ["Location": redirected.url!.appendingPathComponent("chat/completions").absoluteString],
                body: Data(), staysOpen: false))
            defer { source.stop() }
            let provider = try await makeProvider(source, key: "synthetic-redirect-test-key")
            do {
                _ = try await provider.generateResponse(query: "Fixture", context: nil, conversationHistory: [], model: nil)
                Issue.record("A redirect response must fail without a second request")
            } catch {
                #expect(error is AIProviderError)
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(source.requests.count == 1)
            #expect(source.requests.first?.authorization == "Bearer synthetic-redirect-test-key")
            #expect(destination.requests.isEmpty)
            #expect(destination.acceptedConnectionCount == 0)
        }
    }

    @Test func actualTransportReturnsUnicodeAndDoesNotSendCookies() async throws {
        let fixture = try await CompatibleHTTPFixture.start(response: .complete(
            #"{"choices":[{"message":{"content":"Hello 🌐"}}]}"#))
        defer { fixture.stop() }
        let provider = try await makeProvider(fixture)
        let response = try await provider.generateResponse(query: "Fixture", context: nil, conversationHistory: [], model: nil)
        #expect(response.text == "Hello 🌐")
        let request = try #require(fixture.requests.first)
        #expect(request.path == "/v1/chat/completions")
        #expect(request.authorization == nil)
        #expect(request.cookie == nil)
    }

    @Test func doneEventClosesTheUnderlyingSocketBeforeServerEOF() async throws {
        let fixture = try await CompatibleHTTPFixture.start(response: .stream(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello 🌐\"}}]}\n\ndata: [DONE]\n\n"))
        defer { fixture.stop() }
        let provider = try await makeProvider(fixture)
        let stream = try await provider.generateStreamingResponse(query: "Fixture", context: nil, conversationHistory: [], model: nil)
        var result: Result<String, Error>?
        let consumer = Task { @MainActor in
            do {
                var text = ""
                for try await chunk in stream { text += chunk }
                result = .success(text)
            } catch { result = .failure(error) }
        }
        defer { consumer.cancel() }
        #expect(await eventually { result != nil })
        let completed = try #require(result)
        #expect(try completed.get() == "Hello 🌐")
        // The fixture never sends a terminating chunk or closes this connection.
        #expect(await eventually { fixture.clientClosedConnectionCount == 1 })
    }

    @Test func stopAndRevocationCloseTheUnderlyingStreamingSocket() async throws {
        for revoke in [false, true] {
            let fixture = try await CompatibleHTTPFixture.start(response: .stream(
                "data: {\"choices\":[{\"delta\":{\"content\":\"ready\"}}]}\n\n"))
            defer { fixture.stop() }
            let provider = try await makeProvider(fixture)
            let stream = try await provider.generateStreamingResponse(query: "Fixture", context: nil, conversationHistory: [], model: nil)
            var receivedText = false
            let consumer = Task { @MainActor in
                do { for try await _ in stream { receivedText = true } }
                catch { /* Cancellation is expected. Socket closure is the assertion. */ }
            }
            defer { consumer.cancel() }
            #expect(await eventually { receivedText })
            if revoke { provider.revoke() } else { consumer.cancel() }
            #expect(await eventually { fixture.clientClosedConnectionCount == 1 })
            if revoke { #expect(!(await provider.isReady())) }
        }
    }

    @Test func oversizedBodyStopsReadingAndClosesTheUnderlyingSocket() async throws {
        let bytes = Data(repeating: 97, count: CompatibleURLSessionTransport.maximumResponseBytes + 1)
        let fixture = try await CompatibleHTTPFixture.start(response: .init(
            status: 200, headers: ["Content-Type": "application/json"], body: bytes, staysOpen: true))
        defer { fixture.stop() }
        var request = URLRequest(url: fixture.baseURL)
        request.timeoutInterval = 5
        do {
            _ = try await CompatibleURLSessionTransport().data(for: request)
            Issue.record("An oversized response must be rejected")
        } catch {
            #expect(error is AIProviderError)
        }
        #expect(await eventually { fixture.clientClosedConnectionCount == 1 })
    }

    @Test func oversizedSSELineStopsReadingAndClosesTheUnderlyingSocket() async throws {
        let fixture = try await CompatibleHTTPFixture.start(response: .stream(String(repeating: "a", count: 65_537)))
        defer { fixture.stop() }
        var request = URLRequest(url: fixture.baseURL)
        request.timeoutInterval = 5
        let connection = try await CompatibleURLSessionTransport().lines(for: request)
        defer { connection.cancel() }
        do {
            for try await _ in connection.lines {}
            Issue.record("An oversized SSE line must be rejected")
        } catch {
            #expect(error is AIProviderError)
        }
        #expect(await eventually { fixture.clientClosedConnectionCount == 1 })
    }

    private func makeProvider(_ fixture: CompatibleHTTPFixture, key: String? = nil) async throws -> CompatibleAPIProvider {
        let configuration = try CompatibleAPIConfiguration(endpoint: fixture.baseURL.absoluteString,
            modelID: "fixture-model", usesAPIKey: key != nil)
        let provider = CompatibleAPIProvider(configuration: configuration, keys: FixtureOnlyAPIKey(key: key))
        try await provider.initialize()
        return provider
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return condition()
    }
}

private struct FixtureOnlyAPIKey: CompatibleAPIKeyStorage {
    let key: String?
    func compatibleAPIKey(for configuration: CompatibleAPIConfiguration) throws -> String? { key }
    func storeCompatibleAPIKey(_ key: String?, for configuration: CompatibleAPIConfiguration) throws {
        throw URLError(.unsupportedURL)
    }
}

private final class CompatibleHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        var staysOpen: Bool

        static func complete(_ text: String) -> Self {
            .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8), staysOpen: false)
        }
        static func stream(_ text: String) -> Self {
            .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(text.utf8), staysOpen: true)
        }
    }
    struct Request: Sendable {
        let path: String
        let authorization: String?
        let cookie: String?
    }

    private let listener: NWListener
    private let response: Response
    private let queue = DispatchQueue(label: "Web.CompatibleAPITransportTests")
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var accepted = 0
    private var clientClosed = 0
    // Connection ownership is confined to queue; observable counts use lock.
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    var requests: [Request] { lock.withLock { recordedRequests } }
    var acceptedConnectionCount: Int { lock.withLock { accepted } }
    var clientClosedConnectionCount: Int { lock.withLock { clientClosed } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/v1")! }

    private init(response: Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.response = response
    }

    static func start(response: Response) async throws -> CompatibleHTTPFixture {
        let fixture = try CompatibleHTTPFixture(response: response)
        fixture.listener.newConnectionHandler = { [weak fixture] connection in fixture?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = FixtureStartupCompletion(continuation)
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            fixture.queue.asyncAfter(deadline: .now() + 5) {
                completion.finish(.failure(URLError(.timedOut)))
            }
            fixture.listener.start(queue: fixture.queue)
        }
        return fixture
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        lock.withLock { accepted += 1 }
        connection.start(queue: queue)
        receiveRequest(connection, id: id, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 65_536 else { connection.cancel(); return }
            let separator = Data("\r\n\r\n".utf8)
            if let range = buffer.range(of: separator),
               let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) {
                let lines = text.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if buffer.count - range.upperBound >= length {
                    let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    self.lock.withLock {
                        self.recordedRequests.append(Request(path: path, authorization: headers["authorization"], cookie: headers["cookie"]))
                    }
                    self.sendResponse(connection, id: id)
                    return
                }
            }
            if complete || error != nil { self.connections.removeValue(forKey: id); connection.cancel(); return }
            self.receiveRequest(connection, id: id, accumulated: buffer)
        }
    }

    private func sendResponse(_ connection: NWConnection, id: UUID) {
        var headers = response.headers
        headers["Connection"] = "close"
        if response.staysOpen { headers["Transfer-Encoding"] = "chunked" }
        else { headers["Content-Length"] = String(response.body.count) }
        let head = "HTTP/1.1 \(response.status) Fixture\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        var wire = Data(head.utf8)
        if response.staysOpen {
            wire.append(Data(String(response.body.count, radix: 16).utf8))
            wire.append(Data("\r\n".utf8))
            wire.append(response.body)
            wire.append(Data("\r\n".utf8))
            // Deliberately omit the zero chunk. Only the client can end the stream.
        } else { wire.append(response.body) }
        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            if !self.response.staysOpen || error != nil {
                self.connections.removeValue(forKey: id)
                connection.cancel()
            }
        })
        if response.staysOpen { observeClientClose(connection, id: id) }
    }

    private func observeClientClose(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self else { connection.cancel(); return }
            if complete || error != nil {
                if !self.stopped { self.lock.withLock { self.clientClosed += 1 } }
                self.connections.removeValue(forKey: id)
                connection.cancel()
            } else { self.observeClientClose(connection, id: id) }
        }
    }
}

/// Listener readiness, failure and timeout may race. Resume the waiter once.
private final class FixtureStartupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
