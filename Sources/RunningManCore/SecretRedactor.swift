import Foundation

/// Defense in depth for diagnostics. The app never reads runner credential files.
///
/// Log lines are job output, so every pattern must stay linear: no nested quantifiers,
/// and each unbounded run is delimited by a character it cannot contain.
public enum SecretRedactor {
    public static func redact(_ text: String) -> String {
        // One UTF-16 buffer for every pass and check. Bridging a native String per pattern, or
        // searching it through the String overlay, costs more than the matching itself.
        var buffer = NSMutableString(string: text)
        // JSON variables can place isSecret before or after value, across lines.
        if buffer.range(of: "isSecret", options: .caseInsensitive).location != NSNotFound {
            buffer = NSMutableString(string: replacing(flatObject, in: text) { object in
                guard secretFlag.firstMatch(in: object, range: NSRange(object.startIndex..., in: object)) != nil else { return object }
                return replacing(secretFlagValue, in: object, with: "$1\"[REDACTED]\"")
            })
        }
        for rule in rules where rule.applies(to: buffer) {
            rule.expression.replaceMatches(in: buffer, range: NSRange(location: 0, length: buffer.length), withTemplate: rule.template)
        }
        return buffer as String
    }

    /// Flat objects only, so a block never spans into a sibling and the scan stays linear.
    private static let flatObject = compile(#"\{[^{}]*\}"#)
    private static let secretFlag = compile(#"(?i)\"isSecret\"\s*:\s*true"#)
    private static let secretFlagValue = compile(#"(?is)(\"value\"\s*:\s*)\"(?:\\.|[^\"\\])*\""#)

    /// Names that mark a secret anywhere in an identifier (GITHUB_TOKEN, PGPASSWORD, sessionToken).
    /// Generic words need a non-letter on their left, so RUNNER_SECRET matches while isSecret does not;
    /// underscores and digits count as boundaries, unlike \b.
    /// Every alternative contains one of `credentialWords`; keep the two in sync.
    private static let credentialName = #"(?:access[_-]?token|refresh[_-]?token|registration[_-]?token|client[_-]?secret|password|passwd|token|(?<![A-Za-z])(?:secret(?:[_-]?access)?(?:[_-]?key)?|api[_-]?key|private[_-]?key))"#
    private static let credentialWords = ["token", "secret", "passw", "key"]
    /// A double- or single-quoted value. Each quote is captured so the template can restore it.
    private static let quotedValue = #"(?:(\")(?:\\.|[^\"\\])*\"|(')[^'\r\n]*')"#

    // Order matters: whole-value shapes (private keys, URLs, bearer tokens, headers) run before
    // key=value rules, which would otherwise consume only the first word and expose the rest.
    private static let rules: [Rule] = [
        Rule(#"(?s)-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----(?:.*?-----END (?:[A-Z ]*PRIVATE KEY)-----|.*$)"#, "[REDACTED PRIVATE KEY]"),
        Rule(#"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,})\b"#, "[REDACTED]"),
        Rule(#"\bglpat-[A-Za-z0-9_.-]{20,}"#, "[REDACTED]"),
        Rule(#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, "[REDACTED]"),
        Rule(#"\bnpm_[A-Za-z0-9]{36}\b"#, "[REDACTED]"),
        Rule(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, "[REDACTED]"),
        Rule(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[REDACTED]"),
        // Any scheme, anchored at the literal separator: user:password, or token-only userinfo
        // long enough not to be a login such as git@.
        Rule(#"(://)(?:[^/\s:@]+:[^/\s@]+|[^/\s:@]{16,})@"#, "$1[REDACTED]@"),
        Rule(#"(?i)(authorization\s*[:=]\s*\"?(?:bearer|basic|token)\s+)[^\s\"',;]+"#, "$1[REDACTED]"),
        // A token has a digit or symbol, so prose such as "Bearer authentication failed" stays readable.
        Rule(#"(?i)\b(bearer[ \t]+)(?=[A-Za-z0-9._~+/-]{12,})[A-Za-z]*[0-9._~+/-][A-Za-z0-9._~+/-]*=*"#, "$1[REDACTED]"),
        Rule(#"(?i)\b((?:set-)?cookie[ \t]*:[ \t]*)[^\r\n]+"#, "$1[REDACTED]"),
        Rule(#"(?i)(--(?:[a-z]{1,32}-)?(?:token|pat|password|passwd|secret|api-key)(?:\s+|=))(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s\"']+)"#, "$1[REDACTED]"),
        Rule(#"(?i)([?&](?:access_token|token|sig|signature|client_secret|password|code)=)[^&\s\"']+"#, "$1[REDACTED]"),
        // Quoted header values in JSON: "Authorization": "Bearer x", "Set-Cookie": "a=b".
        Rule(#"(?i)((?:authorization|(?<![A-Za-z])cookie)[\"']?\s*[:=]\s*)\#(quotedValue)"#, "$1$2$3[REDACTED]$2$3",
             requiredWords: ["authorization", "cookie"]),
        // key = "value", 'key': 'value' and key: value. Unquoted values need an unquoted key, so JSON
        // flags such as "hasPassword": true survive. Skipping an existing marker keeps redaction
        // idempotent and leaves "[REDACTED PRIVATE KEY]" whole. A scheme word (token: Basic x)
        // is consumed with its value so it cannot shield the credential.
        Rule(#"(?i)(\#(credentialName))(?:([\"']?\s*[:=]\s*)\#(quotedValue)|(\s*[:=]\s*)(?!\[REDACTED[\] ])(?:(?:basic|bearer|token)[ \t]+)?[^\s\"',;{}]+)"#,
             "$1$2$5$3$4[REDACTED]$3$4", requiredWords: credentialWords)
    ]

    private struct Rule {
        let expression: NSRegularExpression
        let template: String
        /// Words every match contains; the expensive name-based rules are skipped when none occurs.
        let requiredWords: [String]
        init(_ pattern: String, _ template: String, requiredWords: [String] = []) {
            expression = compile(pattern); self.template = template; self.requiredWords = requiredWords
        }
        func applies(to text: NSString) -> Bool {
            requiredWords.isEmpty || requiredWords.contains { text.range(of: $0, options: .caseInsensitive).location != NSNotFound }
        }
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants covered by tests; a typo must fail loudly rather than silently skip redaction.
        do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("Invalid redaction pattern \(pattern): \(error)") }
    }
    private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    /// Appends segments instead of replacing in place, so many matches stay linear.
    private static func replacing(_ expression: NSRegularExpression, in text: String, transform: (String) -> String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += transform(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
