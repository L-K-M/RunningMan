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
    /// Drops any in-memory copy after the server rejected it, so the next request reads the store again.
    func invalidateToken(for serverURL: URL) async
}

public extension ForgejoTokenProviding {
    func invalidateToken(for serverURL: URL) async {}
}

public protocol ForgejoTokenSaving: Sendable {
    func setToken(_ token: String, for serverURL: URL) async throws
}

/// Holds one typed token in memory so a connection can be verified before anything is saved.
struct EphemeralForgejoToken: ForgejoTokenProviding {
    let origin: URL
    let token: String
    func token(for serverURL: URL) async throws -> String? {
        try ForgejoConnectionStore.origin(for: serverURL) == origin ? token : nil
    }
}

/// Secret persistence below the store: the login Keychain in the app, an in-memory fake in tests.
protocol ForgejoSecretStorage: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

private struct KeychainSecretStorage: ForgejoSecretStorage {
    let service: String
    func read(account: String) throws -> String? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
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
    func write(_ value: String, account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
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
    func delete(account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw ForgejoAPIError("Could not remove the Forgejo token from Keychain.") }
        #endif
    }
}

/// One credential per HTTPS origin. Credentials never enter preferences, argv or diagnostics.
public actor ForgejoConnectionStore: ForgejoTokenProviding, ForgejoTokenSaving {
    private let storage: any ForgejoSecretStorage
    /// Tokens read or saved in this session, keyed by origin. Status checks and
    /// queue monitoring run every few seconds, and each Keychain read can raise an
    /// access prompt for an ad-hoc signed build, so the Keychain is read once per
    /// origin until a token is replaced, removed or rejected with HTTP 401.
    private var cachedTokens: [String: String] = [:]
    public init() { storage = KeychainSecretStorage(service: "com.runningman.forgejo-api") }
    init(storage: any ForgejoSecretStorage) { self.storage = storage }
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
    /// The form in which a typed token is both verified and saved.
    static func validatedToken(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 4096, !value.contains("\n"), !value.contains("\r") else {
            throw ForgejoAPIError("Enter a valid Forgejo access token.")
        }
        return value
    }
    public func setToken(_ token: String, for serverURL: URL) throws {
        let key = try Self.origin(for: serverURL).absoluteString
        let value = try Self.validatedToken(token)
        try storage.write(value, account: key)
        cachedTokens[key] = value
    }
    public func token(for serverURL: URL) throws -> String? {
        let key = try Self.origin(for: serverURL).absoluteString
        if let cached = cachedTokens[key] { return cached }
        guard let value = try storage.read(account: key) else { return nil }
        cachedTokens[key] = value
        return value
    }
    public func invalidateToken(for serverURL: URL) {
        guard let key = try? Self.origin(for: serverURL).absoluteString else { return }
        cachedTokens[key] = nil
    }
    public func removeToken(for serverURL: URL) throws {
        let key = try Self.origin(for: serverURL).absoluteString
        cachedTokens[key] = nil
        try storage.delete(account: key)
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
    /// Largest response body RunningMan inspects; runner and queue listings are far smaller.
    static let maximumResponseBytes = 8 * 1024 * 1024
    private static let oversizedResponse = "Forgejo returned too much data to inspect safely."
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
        do { return try await load(request) }
        catch let error as ForgejoAPIError where error.statusCode == 401 {
            // Drop the cached copy of a rejected token so the next request reads the credential store again.
            await tokens.invalidateToken(for: origin)
            throw error
        }
    }

    private func load(_ request: URLRequest) async throws -> Data {
        do {
            #if os(macOS)
            let (stream, response) = try await session.bytes(for: request)
            // Decide from the response head, so an error page or an oversized
            // listing is never downloaded.
            let declaredLength: Int
            do { declaredLength = try Self.acceptedLength(of: response) }
            catch { stream.task.cancel(); throw error }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(declaredLength)
            for try await byte in stream {
                guard bytes.count < Self.maximumResponseBytes else { stream.task.cancel(); throw ForgejoAPIError(Self.oversizedResponse) }
                bytes.append(byte)
            }
            return Data(bytes)
            #else
            let (data, response) = try await session.data(for: request)
            _ = try Self.acceptedLength(of: response)
            guard data.count <= Self.maximumResponseBytes else { throw ForgejoAPIError(Self.oversizedResponse) }
            return data
            #endif
        } catch let error as ForgejoAPIError { throw error }
        catch { throw Self.transportError(error) }
    }

    /// Returns the declared body length (0 when unknown) for a successful response
    /// that fits the inspection limit, and throws for anything else.
    private static func acceptedLength(of response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else { throw ForgejoAPIError("Forgejo returned an invalid response.") }
        guard (200...299).contains(response.statusCode) else { throw statusError(for: response) }
        guard response.expectedContentLength <= maximumResponseBytes else { throw ForgejoAPIError(oversizedResponse) }
        return max(0, Int(response.expectedContentLength))
    }

    /// Server-supplied error text is never shown; the status alone selects the advice.
    private static func statusError(for response: HTTPURLResponse) -> ForgejoAPIError {
        let code = response.statusCode
        let message: String
        switch code {
        case 300...399:
            let target = redirectTarget(response.value(forHTTPHeaderField: "Location"), relativeTo: response.url).map { " to " + $0 } ?? ""
            message = "The Forgejo server redirected\(target) (HTTP \(code)). RunningMan follows redirects only within the same HTTPS address. Enter the server’s final HTTPS URL."
        case 401:
            message = "Forgejo rejected the access token (HTTP 401). It may be mistyped, expired or revoked. Create a new token and connect the server again."
        case 403:
            message = "Forgejo denied access (HTTP 403). The access token lacks permission for this scope or action. Check the token’s scopes and your role on the server."
        case 404:
            message = "Forgejo could not find this resource (HTTP 404). Check the repository, organization or runner, or update Forgejo if this version does not support the request."
        case 429:
            message = "The Forgejo server is limiting requests (HTTP 429). Wait a few minutes before trying again."
        case 500...599:
            message = "The Forgejo server reported an error (HTTP \(code)). Try again later, or check the server’s logs if it continues."
        default:
            message = "Forgejo API returned HTTP \(code). Check server access and token permissions."
        }
        return ForgejoAPIError(message, statusCode: code, retryAfter: retryDate(from: response.value(forHTTPHeaderField: "Retry-After"), now: Date()))
    }

    /// Retry-After holds either delay seconds or an HTTP-date (RFC 9110, section 10.2.3).
    /// The pause is kept between 30 seconds and one hour so a server can neither
    /// cause a request storm nor stop monitoring for days.
    private static func retryDate(from value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let delay: TimeInterval
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            delay = TimeInterval(value) ?? .greatestFiniteMagnitude
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            // IMF-fixdate, then the obsolete RFC 850 and asctime forms recipients must accept.
            var date: Date?
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] where date == nil {
                formatter.dateFormat = format
                date = formatter.date(from: value)
            }
            guard let date else { return nil }
            delay = date.timeIntervalSince(now)
        }
        return now.addingTimeInterval(min(3600, max(30, delay)))
    }

    private static func redirectTarget(_ location: String?, relativeTo base: URL?) -> String? {
        guard let location, let target = URL(string: location, relativeTo: base)?.absoluteURL,
              let scheme = target.scheme?.lowercased(), let host = target.host?.lowercased(), !host.isEmpty, host.count <= 253 else { return nil }
        return scheme + "://" + host + (target.port.map { ":\($0)" } ?? "")
    }

    /// Cancellation stays a cancellation so callers can tell it from an outage.
    private static func transportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        switch (error as? URLError)?.code {
        case .cancelled?:
            return CancellationError()
        case .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?,
             .serverCertificateNotYetValid?, .secureConnectionFailed?, .clientCertificateRejected?, .clientCertificateRequired?:
            return ForgejoAPIError("The Forgejo server’s HTTPS certificate could not be verified. Check the server address and its certificate; a certificate from a private authority must be trusted by macOS first.")
        case .timedOut?:
            return ForgejoAPIError("The Forgejo server did not respond in time. Check its URL and network connection, then try again.")
        default:
            return ForgejoAPIError("The Forgejo server could not be reached. Check its URL and network connection.")
        }
    }
}
