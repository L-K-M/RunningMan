import Foundation
import RunningManCore
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ForgejoAPIError: LocalizedError, Sendable {
    public var statusCode: Int?
    public var retryAfter: Date?
    public var message: String
    public var errorDescription: String? { message }
    public init(_ message: String, statusCode: Int? = nil, retryAfter: Date? = nil) {
        self.message = SecretRedactor.redact(message); self.statusCode = statusCode; self.retryAfter = retryAfter
    }
}

public protocol ForgejoTokenProviding: Sendable {
    func token(for serverURL: URL) async throws -> String?
}

/// One credential per HTTPS origin. Credentials never enter preferences, argv or diagnostics.
public actor ForgejoConnectionStore: ForgejoTokenProviding {
    private let service = "com.runningman.forgejo-api"
    public init() {}
    public static func origin(for url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw ForgejoAPIError("Use an HTTPS Forgejo server root URL without credentials, a path or query parameters.")
        }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let origin = parts.url else { throw ForgejoAPIError("The Forgejo server URL is invalid.") }
        return origin
    }
    public func setToken(_ token: String, for serverURL: URL) throws {
        let key = try Self.origin(for: serverURL).absoluteString
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096, !value.contains("\n"), !value.contains("\r") else {
            throw ForgejoAPIError("Enter a valid Forgejo access token.")
        }
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var addition = query; attributes.forEach { addition[$0.key] = $0.value }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw ForgejoAPIError("Could not save the Forgejo token in your login Keychain.") }
        } else if result != errSecSuccess { throw ForgejoAPIError("Could not update the Forgejo token in your login Keychain.") }
        #else
        throw ForgejoAPIError("Forgejo credentials require the macOS Keychain.")
        #endif
    }
    public func token(for serverURL: URL) throws -> String? {
        let key = try Self.origin(for: serverURL).absoluteString
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ForgejoAPIError("Could not read the Forgejo token from your login Keychain.")
        }
        return value
        #else
        return nil
        #endif
    }
    public func removeToken(for serverURL: URL) throws {
        let key = try Self.origin(for: serverURL).absoluteString
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw ForgejoAPIError("Could not remove the Forgejo token from Keychain.") }
        #endif
    }
}

public protocol ForgejoAPIRequesting: Sendable {
    func request(path: String, serverURL: URL, method: String, body: Data?) async throws -> Data
}

enum ForgejoRedirectPolicy {
    static func permits(from old: URL, to next: URL) -> Bool {
        old.scheme == "https" && next.scheme == "https" && old.host?.lowercased() == next.host?.lowercased()
            && (old.port ?? 443) == (next.port ?? 443) && next.user == nil && next.password == nil
    }
}

private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let old = task.originalRequest?.url, let next = request.url,
              ForgejoRedirectPolicy.permits(from: old, to: next) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public actor ForgejoAPIClient: ForgejoAPIRequesting {
    private let tokens: any ForgejoTokenProviding
    private let session: URLSession
    public init(tokens: any ForgejoTokenProviding = ForgejoConnectionStore(),
                configuration: URLSessionConfiguration = .ephemeral) {
        self.tokens = tokens
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        self.session = URLSession(configuration: configuration, delegate: SameOriginRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func request(path: String, serverURL: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { throw ForgejoAPIError("Unsupported Forgejo API method.") }
        let origin = try ForgejoConnectionStore.origin(for: serverURL)
        guard !path.contains("://"), !path.contains("\\"), !path.contains("\n"), !path.contains("\r"),
              !path.split(separator: "/").contains("..") else { throw ForgejoAPIError("Invalid Forgejo API path.") }
        let relative = path.hasPrefix("/api/v1/") ? String(path.dropFirst(8)) : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: origin.absoluteString + "/api/v1/" + relative),
              url.scheme == "https", url.host?.lowercased() == origin.host?.lowercased(), (url.port ?? 443) == (origin.port ?? 443) else { throw ForgejoAPIError("Invalid Forgejo API URL.") }
        guard let token = try await tokens.token(for: origin), !token.isEmpty else { throw ForgejoAPIError("Connect this Forgejo server in Settings with an access token.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            #if os(macOS)
            let (stream, response) = try await session.bytes(for: request)
            var bytes = Data()
            for try await byte in stream {
                guard bytes.count < 8 * 1024 * 1024 else { throw ForgejoAPIError("Forgejo returned too much data to inspect safely.") }
                bytes.append(byte)
            }
            #else
            let (bytes, response) = try await session.data(for: request)
            #endif
            guard let response = response as? HTTPURLResponse else { throw ForgejoAPIError("Forgejo returned an invalid response.") }
            guard (200...299).contains(response.statusCode) else {
                let backoff = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).map { Date().addingTimeInterval(min(3600, max(30, $0))) }
                throw ForgejoAPIError("Forgejo API returned HTTP \(response.statusCode). Check server access and token permissions.", statusCode: response.statusCode, retryAfter: backoff)
            }
            guard bytes.count <= 8 * 1024 * 1024 else { throw ForgejoAPIError("Forgejo returned too much data to inspect safely.") }
            return bytes
        } catch let error as ForgejoAPIError { throw error }
        catch { throw ForgejoAPIError("The Forgejo server could not be reached. Check its URL and network connection.") }
    }
}
