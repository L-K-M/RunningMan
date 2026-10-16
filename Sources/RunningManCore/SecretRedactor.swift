import Foundation

/// Defense in depth for diagnostics. The app never reads runner credential files.
public enum SecretRedactor {
    public static func redact(_ text: String) -> String {
        var result = text
        // JSON variables can place isSecret before or after value, across lines.
        result = replacing(#"(?is)(\"[^\"]+\"\s*:\s*\{[^{}]*\"isSecret\"\s*:\s*true[^{}]*\})"#, in: result) { match in
            replacing(#"(?is)(\"value\"\s*:\s*)\"(?:\\.|[^\"\\])*\""#, in: match, with: "$1\"[REDACTED]\"")
        }
        for (expression, replacement) in patterns {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
    private static let patterns: [(NSRegularExpression, String)] = {
        let values: [(String, String)] = [
            (#"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})\b"#, "[REDACTED]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[REDACTED]"),
            (#"(?i)(authorization\s*[:=]\s*\"?(?:bearer|basic|token)\s+)[^\s\"',;]+"#, "$1[REDACTED]"),
            (#"(?i)(--(?:token|pat|password|secret)(?:\s+|=))[^\s\"']+"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:access_token|token|sig|signature|client_secret|password|code)=)[^&\s\"']+"#, "$1[REDACTED]"),
            (#"(?i)(\"?(?:access[_-]?token|refresh[_-]?token|registration[_-]?token|client[_-]?secret|password|authorization|token)\"?\s*[:=]\s*)\"(?:\\.|[^\"\\])*\""#, "$1\"[REDACTED]\""),
            (#"(?i)((?:access[_-]?token|refresh[_-]?token|registration[_-]?token|client[_-]?secret|password|token)\s*[:=]\s*)[^\s\"',;{}]+"#, "$1[REDACTED]"),
            (#"(?i)(https?://)[^/\s:@]+:[^/\s@]+@"#, "$1[REDACTED]@"),
            (#"(?s)-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----(?:.*?-----END (?:[A-Z ]*PRIVATE KEY)-----|.*$)"#, "[REDACTED PRIVATE KEY]")
        ]
        return values.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()
    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    private static func replacing(_ pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
