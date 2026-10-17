import Foundation

/// Read limits shared by the GitHub and Forgejo log monitors.
enum DiagnosticLogLimits {
    /// A file larger than this is not read from the start the first time it is seen.
    static let largeFile: UInt64 = 1024 * 1024
    /// The newest bytes read from a large first-seen file.
    static let tailWindow = 512 * 1024
    static let readChunk = 1024 * 1024
    /// An unterminated line longer than this is dropped rather than retained.
    static let partialLine = 128 * 1024
    /// Job-parsing patterns only look at this many leading bytes of a line.
    static let parsedLinePrefix = 8 * 1024
    /// Private-key mode ends after this many hidden lines even without an END marker.
    static let privateKeyLines = 200
    static let liveTail = 64 * 1024

    /// The leading part of a line that job-parsing patterns may inspect, so a corrupt
    /// or hostile multi-megabyte line cannot make a pattern scan run for minutes.
    static func parsedPrefix(_ line: String) -> String {
        line.utf8.count > parsedLinePrefix ? String(decoding: line.utf8.prefix(parsedLinePrefix), as: UTF8.self) : line
    }
}

/// The runner fields read per log line. InstalledRunner.id standardizes a file URL,
/// which touches the file system, so the monitors resolve it once per scan.
struct LogRunnerContext {
    let id: String
    let repository: String
    init(_ runner: InstalledRunner) { id = runner.id; repository = runner.repository }
}

/// A diagnostic log opened for reading. The size and identity come from the open
/// descriptor, so they describe the file that is actually read.
struct DiagnosticLogFile {
    enum OpenError: Error { case missing, symbolicLink, notRegularFile }
    let handle: FileHandle
    let size: UInt64
    /// Device and inode, used to notice a log replaced at the same path.
    let identity: String

    /// O_NOFOLLOW makes the kernel refuse a final symbolic link, so a log swapped for a
    /// link to a credential file after the directory listing is still never read.
    /// O_NONBLOCK keeps a FIFO named like a log from blocking the reader; fstat then
    /// rejects it along with every other non-regular file.
    static func open(_ url: URL) throws -> DiagnosticLogFile {
        let descriptor = Foundation.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { throw OpenError.missing }
            if code == ELOOP { throw OpenError.symbolicLink }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw OpenError.notRegularFile }
        return DiagnosticLogFile(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            size: UInt64(max(0, status.st_size)), identity: "\(status.st_dev):\(status.st_ino)")
    }
}

/// The newest lines of a live log within a byte budget. Lines are stored as read and
/// redacted when the tail is rendered, at most once each, so lines that scroll out
/// between renders never cost a redaction. The owning actor only hands out rendered,
/// redacted text.
struct LogTailBuffer {
    private struct Line { var text: String; var bytes: Int; var redacted: Bool }
    private static let shortenedMarker = " [line shortened]"
    private let capacity: Int
    private let maxLineBytes: Int
    private var lines: [Line] = []
    /// Index of the oldest retained line; earlier slots are compacted away in batches.
    private var head = 0
    private var byteCount = 0
    private var changed = false

    init(capacity: Int = DiagnosticLogLimits.liveTail) {
        self.capacity = capacity; maxLineBytes = capacity / 4
    }

    mutating func append(_ text: String) {
        let bytes = text.utf8.count + 1
        // An oversized line is redacted whole before it is shortened, so the cut can
        // never leave a secret fragment that no longer matches a redaction pattern.
        let line = bytes > maxLineBytes ? shortened(SecretRedactor.redact(text)) : Line(text: text, bytes: bytes, redacted: false)
        lines.append(line); byteCount += line.bytes; changed = true
        trim()
    }

    /// The redacted tail, or nil when nothing was appended since the last render.
    mutating func render() -> String? {
        guard changed else { return nil }
        changed = false
        for index in head..<lines.count where !lines[index].redacted {
            let safe = SecretRedactor.redact(lines[index].text)
            let line = safe.utf8.count + 1 > maxLineBytes ? shortened(safe) : Line(text: safe, bytes: safe.utf8.count + 1, redacted: true)
            byteCount += line.bytes - lines[index].bytes
            lines[index] = line
        }
        trim()
        var text = ""
        text.reserveCapacity(byteCount)
        for line in lines[head...] { text += line.text; text += "\n" }
        return text
    }

    /// Every retained line is at most `maxLineBytes`, a quarter of the capacity, so
    /// trimming always keeps the newest line.
    private mutating func trim() {
        while byteCount > capacity, head < lines.count - 1 { byteCount -= lines[head].bytes; head += 1 }
        if head >= 256, head * 2 >= lines.count { lines.removeFirst(head); head = 0 }
    }

    private func shortened(_ safe: String) -> Line {
        // A cut inside a multi-byte character decodes to one replacement character,
        // at most two bytes longer than the cut-off bytes it replaces.
        let keep = maxLineBytes - Self.shortenedMarker.utf8.count - 4
        let text = String(decoding: safe.utf8.prefix(keep), as: UTF8.self) + Self.shortenedMarker
        return Line(text: text, bytes: text.utf8.count + 1, redacted: true)
    }
}

enum DiagnosticTimestamp {
    /// What may separate the date from the time.
    enum Separator {
        /// ISO 8601 only, as ISO8601DateFormatter accepts it.
        case letterT
        /// The GitHub runner writes a space; older code replaced it with "T" before parsing.
        case spaceOrLetterT
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff]Z` exactly, without a formatter. Returns nil
    /// for anything else, including out-of-range fields and more than three fraction
    /// digits, so callers fall back to ISO8601DateFormatter and keep its semantics.
    static func parseUTC(_ text: Substring, separator: Separator) -> Date? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        for byte in text.utf8 { guard bytes.count < 24 else { return nil }; bytes.append(byte) }
        guard bytes.count >= 20, bytes.count != 21, bytes.last == UInt8(ascii: "Z"),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || (separator == .spaceOrLetterT && bytes[10] == UInt8(ascii: " ")),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(bytes[0..<4]), let month = number(bytes[5..<7]), let day = number(bytes[8..<10]),
              let hour = number(bytes[11..<13]), let minute = number(bytes[14..<16]), let second = number(bytes[17..<19]) else { return nil }
        var milliseconds = 0
        if bytes.count > 20 {
            guard bytes[19] == UInt8(ascii: "."), let fraction = number(bytes[20..<(bytes.count - 1)]) else { return nil }
            milliseconds = fraction * [100, 10, 1][bytes.count - 22]
        }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard year >= 1970, (1...12).contains(month), (1...monthDays[month - 1]).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        // Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = shiftedYear / 400, yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second
        // Same arithmetic as the formatter's millisecond result, so dates compare equal.
        return Date(timeIntervalSince1970: Double(seconds * 1_000 + milliseconds) / 1_000)
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}

extension String {
    /// Byte-wise substring test for the literal prechecks run on every log line.
    /// Foundation's `contains` costs microseconds per call; with about ten checks per
    /// line that added seconds to the first scan of a multi-megabyte log.
    func containsBytes(_ literal: String) -> Bool {
        var text = self, literal = literal
        return text.withUTF8 { text in
            literal.withUTF8 { literal in
                guard !literal.isEmpty, let needle = literal.baseAddress else { return true }
                guard let haystack = text.baseAddress, text.count >= literal.count else { return false }
                return memmem(haystack, text.count, needle, literal.count) != nil
            }
        }
    }
}

enum PrivateKeyMarker {
    static func begins(_ line: String) -> Bool { line.containsBytes("-----BEGIN ") && line.containsBytes("PRIVATE KEY-----") }
    static func ends(_ line: String) -> Bool { line.containsBytes("-----END ") && line.containsBytes("PRIVATE KEY-----") }
}

extension ActivityEvent {
    /// The entry both log monitors record the first time a job is seen to finish.
    static func jobFinished(_ job: RunnerJob, at date: Date) -> ActivityEvent {
        ActivityEvent(date: date, runnerID: job.runnerID, title: "Job \(job.outcome.title.lowercased())", detail: job.name,
            kind: job.outcome == .success ? .success : job.outcome == .failure ? .failure : .warning)
    }
}
