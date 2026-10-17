import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RunningManServices

private actor FixtureTokenStore: ForgejoTokenProviding {
    private(set) var requestedHosts: [String] = []
    func token(for serverURL: URL) async throws -> String? {
        requestedHosts.append(serverURL.absoluteString)
        return "fixture-secret-value"
    }
    func hosts() -> [String] { requestedHosts }
}

private struct FixtureReply: Sendable {
    var status = 200
    var headers = ["Content-Type": "application/json"]
    var body = Data(#"{"login":"fixture-user"}"#.utf8)
    var failure: URLError?
    /// Never answers, so a test can cancel a request in flight.
    var holdsResponse = false
}

private final class ForgejoFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [FixtureReply] = [FixtureReply()]
    nonisolated(unsafe) private static var received: [URLRequest] = []
    /// Replies are used in order; the last one answers every further request.
    static func reset(_ next: FixtureReply...) {
        lock.withLock { replies = next.isEmpty ? [FixtureReply()] : next; received = [] }
    }
    static func observed() -> URLRequest? { lock.withLock { received.last } }
    static func requestCount() -> Int { lock.withLock { received.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: FixtureReply = Self.lock.withLock {
            Self.received.append(request)
            return Self.replies.count > 1 ? Self.replies.removeFirst() : Self.replies[0]
        }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        guard !reply.holdsResponse else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 64 * 1024, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Stands in for the login Keychain; tests never touch the real one.
private final class CountingSecretStorage: ForgejoSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var reads = 0
    private var writes = 0
    init(_ values: [String: String] = [:]) { self.values = values }
    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }
    func read(account: String) throws -> String? { lock.withLock { reads += 1; return values[account] } }
    func write(_ value: String, account: String) throws { lock.withLock { writes += 1; values[account] = value } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}

private actor CountingTokenSaver: ForgejoTokenSaving {
    private var saved: [String] = []
    func setToken(_ token: String, for serverURL: URL) { saved.append(token) }
    func tokens() -> [String] { saved }
}

private struct RefusingExecutor: ProcessExecuting {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        XCTFail("Connecting must not run commands"); throw CancellationError()
    }
}

private func fixtureClient(tokens: any ForgejoTokenProviding) -> ForgejoAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ForgejoFixtureProtocol.self]
    return ForgejoAPIClient(tokens: tokens, configuration: configuration)
}

final class ForgejoAPIClientTests: XCTestCase {
    private let server = URL(string: "https://forge.example")!
    override func setUp() { ForgejoFixtureProtocol.reset() }

    func testRedirectPolicyNeverForwardsAuthenticationAcrossOrigins() {
        let original = URL(string: "https://forge.example/api/v1/user")!
        XCTAssertTrue(ForgejoRedirectPolicy.permits(from: original, to: URL(string: "https://forge.example:443/api/v1/user?follow=1")!))
        for target in ["https://other.example/api/v1/user", "http://forge.example/user", "https://forge.example:8443/user", "https://name@forge.example/user"] {
            XCTAssertFalse(ForgejoRedirectPolicy.permits(from: original, to: URL(string: target)!))
        }
    }
    func testAPIUsesOriginScopedSecretAndPreservesQuery() async throws {
        let credentials = FixtureTokenStore()
        let client = fixtureClient(tokens: credentials)
        let result = try await client.request(path: "/repos/example/project/actions/runs?limit=20&page=1", serverURL: server)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("fixture-user"))
        let request = ForgejoFixtureProtocol.observed()
        XCTAssertEqual(request?.url?.path, "/api/v1/repos/example/project/actions/runs")
        XCTAssertEqual(request?.url?.query, "limit=20&page=1")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "token fixture-secret-value")
        let hosts = await credentials.hosts(); XCTAssertEqual(hosts, ["https://forge.example"])
    }
    func testUnsafeURLsAndForeignAPIPathsFailBeforeReadingSecrets() async {
        let credentials = FixtureTokenStore()
        let client = fixtureClient(tokens: credentials)
        for (server, path) in [("http://forge.example", "user"), ("https://forge.example/base", "user"), ("https://forge.example", "https://other.example/user"), ("https://forge.example", "../../user")] {
            do { _ = try await client.request(path: path, serverURL: URL(string: server)!); XCTFail("Expected validation refusal") }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret-value")) }
        }
        let hosts = await credentials.hosts(); XCTAssertTrue(hosts.isEmpty)
    }

    private func apiError(_ client: ForgejoAPIClient, file: StaticString = #filePath, line: UInt = #line) async -> ForgejoAPIError? {
        do {
            _ = try await client.request(path: "user", serverURL: server)
            XCTFail("Expected the request to fail", file: file, line: line)
        } catch let error as ForgejoAPIError { return error }
        catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
        return nil
    }
    func testHTTPFailuresExplainTheirCauseAndKeepTheStatusCode() async {
        let client = fixtureClient(tokens: FixtureTokenStore())
        let cases = [(401, "rejected the access token"), (403, "lacks permission"), (404, "could not find"), (503, "server reported an error")]
        for (status, phrase) in cases {
            ForgejoFixtureProtocol.reset(FixtureReply(status: status, body: Data(#"{"message":"server text"}"#.utf8)))
            let error = await apiError(client)
            XCTAssertEqual(error?.statusCode, status)
            XCTAssertNil(error?.retryAfter)
            XCTAssertTrue(error?.message.contains(phrase) == true, error?.message ?? "")
            XCTAssertTrue(error?.message.contains("HTTP \(status)") == true, error?.message ?? "")
            XCTAssertFalse(error?.message.contains("server text") == true, "Server-supplied text is never shown")
        }
        ForgejoFixtureProtocol.reset(FixtureReply(status: 302, headers: ["Location": "https://other.example/api/v1/user"]))
        let redirect = await apiError(client)
        XCTAssertEqual(redirect?.statusCode, 302)
        XCTAssertTrue(redirect?.message.contains("redirected to https://other.example") == true, redirect?.message ?? "")
    }
    func testRetryAfterAcceptsDelaySecondsAndHTTPDates() async throws {
        let client = fixtureClient(tokens: FixtureTokenStore())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let start = Date()
        let cases: [(String, TimeInterval)] = [("120", 120), (formatter.string(from: start.addingTimeInterval(600)), 600),
                                               (formatter.string(from: start.addingTimeInterval(-600)), 30), ("0", 30), ("86400", 3600)]
        for (value, expected) in cases {
            ForgejoFixtureProtocol.reset(FixtureReply(status: 429, headers: ["Retry-After": value]))
            let error = await apiError(client)
            XCTAssertEqual(error?.statusCode, 429)
            let retry = try XCTUnwrap(error?.retryAfter, value)
            XCTAssertEqual(retry.timeIntervalSince(start), expected, accuracy: 5, value)
        }
        for value in ["soon", "-5", "nan"] {
            ForgejoFixtureProtocol.reset(FixtureReply(status: 503, headers: ["Retry-After": value]))
            let error = await apiError(client)
            XCTAssertNil(error?.retryAfter, value)
        }
    }
    func testOversizedResponsesAreRefused() async {
        let client = fixtureClient(tokens: FixtureTokenStore())
        let limit = ForgejoAPIClient.maximumResponseBytes
        ForgejoFixtureProtocol.reset(FixtureReply(headers: ["Content-Length": String(limit + 1)]))
        let declared = await apiError(client)
        XCTAssertTrue(declared?.message.contains("too much data") == true, declared?.message ?? "")
        ForgejoFixtureProtocol.reset(FixtureReply(headers: [:], body: Data(repeating: 0x20, count: limit + 1)))
        let streamed = await apiError(client)
        XCTAssertTrue(streamed?.message.contains("too much data") == true, streamed?.message ?? "")
    }
    func testOneMebibyteResponseRoundTrips() async throws {
        let body = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        ForgejoFixtureProtocol.reset(FixtureReply(headers: ["Content-Length": String(body.count)], body: body))
        let result = try await fixtureClient(tokens: FixtureTokenStore()).request(path: "user", serverURL: server)
        XCTAssertEqual(result, body)
    }
    func testCancelledRequestIsReportedAsCancellation() async {
        ForgejoFixtureProtocol.reset(FixtureReply(holdsResponse: true))
        let client = fixtureClient(tokens: FixtureTokenStore())
        let server = server
        let request = Task { try await client.request(path: "user", serverURL: server) }
        var waited = 0
        while ForgejoFixtureProtocol.requestCount() == 0 && waited < 500 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
    func testUntrustedCertificateGetsACertificateSpecificMessage() async {
        let client = fixtureClient(tokens: FixtureTokenStore())
        for code in [URLError.Code.serverCertificateUntrusted, .secureConnectionFailed, .serverCertificateHasUnknownRoot] {
            ForgejoFixtureProtocol.reset(FixtureReply(failure: URLError(code)))
            let error = await apiError(client)
            XCTAssertNil(error?.statusCode)
            XCTAssertTrue(error?.message.contains("certificate") == true, error?.message ?? "")
        }
    }

    func testSavedTokenIsReadOnceAndReloadedAfterTheServerRejectsIt() async throws {
        let storage = CountingSecretStorage(["https://forge.example": "fixture-secret-value"])
        let client = fixtureClient(tokens: ForgejoConnectionStore(storage: storage))
        for _ in 0..<3 { _ = try await client.request(path: "user", serverURL: server) }
        XCTAssertEqual(storage.readCount, 1)
        ForgejoFixtureProtocol.reset(FixtureReply(status: 401), FixtureReply())
        let rejected = await apiError(client)
        XCTAssertEqual(rejected?.statusCode, 401)
        _ = try await client.request(path: "user", serverURL: server)
        XCTAssertEqual(storage.readCount, 2)
        XCTAssertEqual(ForgejoFixtureProtocol.observed()?.value(forHTTPHeaderField: "Authorization"), "token fixture-secret-value")
    }
    func testSavingAndForgettingATokenUpdateTheCache() async throws {
        let storage = CountingSecretStorage()
        let store = ForgejoConnectionStore(storage: storage)
        let typed = URL(string: "https://Forge.Example:443/")!
        try await store.setToken("  replacement-value \n", for: typed)
        let saved = try await store.token(for: server)
        XCTAssertEqual(saved, "replacement-value")
        XCTAssertEqual(storage.readCount, 0, "A token saved in this session is not read back from the Keychain")
        try await store.removeToken(for: typed)
        let removed = try await store.token(for: server)
        XCTAssertNil(removed)
        XCTAssertEqual(storage.readCount, 1)
        do { try await store.setToken("first\nsecond", for: server); XCTFail("Expected a malformed token to be refused") } catch {}
        XCTAssertEqual(storage.writeCount, 1)
    }

    private func installer(savedTokens: any ForgejoTokenProviding) -> ForgejoRunnerInstaller {
        ForgejoRunnerInstaller(homeDirectory: FileManager.default.temporaryDirectory, executor: RefusingExecutor(),
                               api: fixtureClient(tokens: savedTokens), candidateAPI: { fixtureClient(tokens: $0) })
    }
    func testRejectedCandidateTokenIsNeverSavedAndLeavesTheSavedTokenAlone() async {
        ForgejoFixtureProtocol.reset(FixtureReply(status: 401))
        let savedTokens = FixtureTokenStore()
        let saver = CountingTokenSaver()
        do { _ = try await installer(savedTokens: savedTokens).connect(serverURL: server, candidateToken: " candidate-value ", savingTo: saver); XCTFail("Expected rejection") }
        catch {
            XCTAssertEqual((error as? ForgejoAPIError)?.statusCode, 401)
            XCTAssertFalse(error.localizedDescription.contains("candidate-value"))
        }
        XCTAssertEqual(ForgejoFixtureProtocol.observed()?.value(forHTTPHeaderField: "Authorization"), "token candidate-value")
        let saved = await saver.tokens(); XCTAssertTrue(saved.isEmpty)
        let hosts = await savedTokens.hosts(); XCTAssertTrue(hosts.isEmpty, "The saved token is not consulted for a typed token")
    }
    func testAcceptedCandidateTokenIsSavedAfterVerification() async throws {
        let savedTokens = FixtureTokenStore()
        let saver = CountingTokenSaver()
        let login = try await installer(savedTokens: savedTokens).connect(serverURL: server, candidateToken: "candidate-value\n", savingTo: saver)
        XCTAssertEqual(login, "fixture-user")
        XCTAssertEqual(ForgejoFixtureProtocol.observed()?.value(forHTTPHeaderField: "Authorization"), "token candidate-value")
        let saved = await saver.tokens(); XCTAssertEqual(saved, ["candidate-value"])
        let hosts = await savedTokens.hosts(); XCTAssertTrue(hosts.isEmpty)
    }
    func testConnectedTokenServesLaterRequestsFromTheSharedStore() async throws {
        // The app hands one store to setup, status checks and monitoring.
        let storage = CountingSecretStorage()
        let store = ForgejoConnectionStore(storage: storage)
        _ = try await installer(savedTokens: store).connect(serverURL: server, candidateToken: "candidate-value", savingTo: store)
        _ = try await fixtureClient(tokens: store).request(path: "user", serverURL: server)
        XCTAssertEqual(ForgejoFixtureProtocol.observed()?.value(forHTTPHeaderField: "Authorization"), "token candidate-value")
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.readCount, 0, "The verified token is cached, not read back from the Keychain")
    }
    func testEmptyCandidateChecksTheSavedConnection() async throws {
        let savedTokens = FixtureTokenStore()
        let saver = CountingTokenSaver()
        let login = try await installer(savedTokens: savedTokens).connect(serverURL: server, candidateToken: "  ", savingTo: saver)
        XCTAssertEqual(login, "fixture-user")
        XCTAssertEqual(ForgejoFixtureProtocol.observed()?.value(forHTTPHeaderField: "Authorization"), "token fixture-secret-value")
        let saved = await saver.tokens(); XCTAssertTrue(saved.isEmpty)
        let hosts = await savedTokens.hosts(); XCTAssertEqual(hosts, ["https://forge.example"])
    }
}
