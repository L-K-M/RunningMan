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
private final class ForgejoFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    private static var lastRequest: URLRequest?
    static func observed() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return lastRequest }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.lastRequest = request; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"login":"fixture-user"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class ForgejoAPIClientTests: XCTestCase {
    func testRedirectPolicyNeverForwardsAuthenticationAcrossOrigins() {
        let original = URL(string: "https://forge.example/api/v1/user")!
        XCTAssertTrue(ForgejoRedirectPolicy.permits(from: original, to: URL(string: "https://forge.example:443/api/v1/user?follow=1")!))
        for target in ["https://other.example/api/v1/user", "http://forge.example/user", "https://forge.example:8443/user", "https://name@forge.example/user"] {
            XCTAssertFalse(ForgejoRedirectPolicy.permits(from: original, to: URL(string: target)!))
        }
    }
    func testAPIUsesOriginScopedSecretAndPreservesQuery() async throws {
        let credentials = FixtureTokenStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForgejoFixtureProtocol.self]
        let client = ForgejoAPIClient(tokens: credentials, configuration: configuration)
        let result = try await client.request(path: "/repos/example/project/actions/runs?limit=20&page=1", serverURL: URL(string: "https://forge.example")!)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("fixture-user"))
        let request = ForgejoFixtureProtocol.observed()
        XCTAssertEqual(request?.url?.path, "/api/v1/repos/example/project/actions/runs")
        XCTAssertEqual(request?.url?.query, "limit=20&page=1")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "token fixture-secret-value")
        let hosts = await credentials.hosts(); XCTAssertEqual(hosts, ["https://forge.example"])
    }
    func testUnsafeURLsAndForeignAPIPathsFailBeforeReadingSecrets() async {
        let credentials = FixtureTokenStore()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForgejoFixtureProtocol.self]
        let client = ForgejoAPIClient(tokens: credentials, configuration: configuration)
        for (server, path) in [("http://forge.example", "user"), ("https://forge.example/base", "user"), ("https://forge.example", "https://other.example/user"), ("https://forge.example", "../../user")] {
            do { _ = try await client.request(path: path, serverURL: URL(string: server)!); XCTFail("Expected validation refusal") }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret-value")) }
        }
        let hosts = await credentials.hosts(); XCTAssertTrue(hosts.isEmpty)
    }
}
