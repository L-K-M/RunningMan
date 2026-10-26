import Foundation

// GitHub's runner writes each job's console output to `_diag/pages/{timeline}_{record}_{page}.log`.
// The page whose record is the job ID receives every line of every step, including composite
// actions, and stays on disk until the job ends; step pages are uploaded and deleted about a
// second after their step finishes. Lines are already masked by the runner and start with a
// fractional ISO 8601 timestamp. The worker diagnostic log names the steps and their results with
// whole-second times, so step boundaries come from there, refined by the first line of any step
// page that is still present when RunningMan looks.

/// How a job step ended, as the runner's worker log reports it.
public enum JobStepOutcome: String, Codable, Sendable, Equatable {
    case running, success, failure, cancelled, skipped, unknown

    init(runnerResult: String) {
        switch runnerResult.lowercased() {
        case "succeeded", "succeededwithissues": self = .success
        case "failed": self = .failure
        case "canceled", "cancelled", "abandoned": self = .cancelled
        case "skipped": self = .skipped
        default: self = .unknown
        }
    }
}

/// One line of step output, with the runner's workflow-command marker turned into a kind.
public struct JobStepLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case output, groupHeader, section, command, error, warning, notice, debug, omission }
    /// Increases across the whole job, so identities stay stable while older lines are trimmed.
    public let id: Int
    public let date: Date
    public let text: String
    public let kind: Kind
    /// Whether the line sits inside a `##[group]` section, which GitHub shows collapsed.
    public let isGrouped: Bool

    public init(id: Int, date: Date, text: String, kind: Kind = .output, isGrouped: Bool = false) {
        self.id = id; self.date = date; self.text = text; self.kind = kind; self.isGrouped = isGrouped
    }
}

public struct JobStep: Identifiable, Sendable, Equatable {
    /// The step's position in the job, starting with "Set up job" at 0.
    public let id: Int
    public let name: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: JobStepOutcome
    public let lines: [JobStepLine]

    public init(id: Int, name: String, startedAt: Date, finishedAt: Date?, outcome: JobStepOutcome, lines: [JobStepLine]) {
        self.id = id; self.name = name; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.outcome = outcome; self.lines = lines
    }
}

/// The steps and redacted console output of a GitHub runner's most recent job.
public struct JobStepLog: Sendable, Equatable {
    /// Matches `RunnerJob.id` for the same job.
    public let jobID: String
    public let runnerID: String
    public let isFinished: Bool
    /// False until RunningMan has read any of the job's output, for example when the job ended
    /// and its files were uploaded before the app started.
    public let hasOutput: Bool
    /// True when output was trimmed to the memory bound or may have been uploaded before it was read.
    public let isTruncated: Bool
    /// Changes whenever the steps or their output change.
    public let revision: Int
    public let steps: [JobStep]

    public init(jobID: String, runnerID: String, isFinished: Bool, hasOutput: Bool, isTruncated: Bool,
                revision: Int, steps: [JobStep]) {
        self.jobID = jobID; self.runnerID = runnerID; self.isFinished = isFinished; self.hasOutput = hasOutput
        self.isTruncated = isTruncated; self.revision = revision; self.steps = steps
    }
}

/// Step names, results and whole-second start times of one job, from the worker diagnostic log.
struct JobStepTimeline {
    struct Entry: Equatable {
        var name: String
        var startedAt: Date
        var finishedAt: Date?
        var outcome: JobStepOutcome
    }
    static let setUpName = "Set up job"
    static let completeName = "Complete job"
    private static let maxEntries = 500

    /// The runner's job ID, lowercased; the job's output page is named after it.
    let jobID: String
    private(set) var entries: [Entry]
    private(set) var isFinished = false
    private var isCompleting = false

    init(jobID: String, startedAt: Date) {
        self.jobID = jobID.lowercased()
        entries = [Entry(name: Self.setUpName, startedAt: startedAt, finishedAt: nil, outcome: .running)]
    }

    /// Applies one timestamped worker log line and returns whether the timeline changed.
    ///
    /// Markers include the trace source because composite actions log their inner steps with the
    /// same "Step result" and "Skipping step" messages from `CompositeActionHandler`.
    mutating func consume(_ line: String, date: Date) -> Bool {
        if let name = Self.value(in: line, after: " StepsRunner] Processing step: DisplayName='") {
            guard !isCompleting, entries.count < Self.maxEntries else { return false }
            finishRunning(at: date, outcome: .success)
            let trimmed = name.hasSuffix("'") ? String(name.dropLast()) : name
            entries.append(Entry(name: Self.displayName(trimmed), startedAt: date, finishedAt: nil, outcome: .running))
            return true
        }
        if line.contains(" StepsRunner] Skipping step due to condition evaluation.") {
            return finishLast(at: date, outcome: .skipped)
        }
        if let result = Self.value(in: line, after: " StepsRunner] Step result: ") {
            return finishLast(at: date, outcome: JobStepOutcome(runnerResult: result))
        }
        if line.contains(" JobRunner] Finalize job.") {
            guard !isCompleting else { return false }
            isCompleting = true
            finishRunning(at: date, outcome: .unknown)
            entries.append(Entry(name: Self.completeName, startedAt: date, finishedAt: nil, outcome: .running))
            return true
        }
        if let result = Self.value(in: line, after: " JobRunner] Job result after all job steps finish: ") {
            guard !isFinished else { return false }
            isFinished = true
            // Set up job never handed over to a step, so the job's result is the best evidence of how it ended.
            if entries[0].outcome == .unknown, entries.count <= (isCompleting ? 2 : 1) {
                entries[0].outcome = JobStepOutcome(runnerResult: result)
            }
            finishRunning(at: date, outcome: .success)
            return true
        }
        return false
    }

    private mutating func finishLast(at date: Date, outcome: JobStepOutcome) -> Bool {
        guard let index = entries.lastIndex(where: { $0.outcome == .running }), index > 0 else { return false }
        entries[index].finishedAt = date
        entries[index].outcome = outcome
        return true
    }

    private mutating func finishRunning(at date: Date, outcome: JobStepOutcome) {
        for index in entries.indices where entries[index].outcome == .running {
            entries[index].finishedAt = date
            entries[index].outcome = outcome
        }
    }

    private static func value(in line: String, after marker: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private static func displayName(_ text: String) -> String {
        let redacted = SecretRedactor.redact(text)
        return redacted.count <= 200 ? redacted : String(redacted.prefix(200)) + "…"
    }
}

/// A bounded copy of one job's console output. The runner deletes page files after uploading
/// them, so output read here is kept until the runner starts another job.
struct JobOutputCapture {
    private struct PageFile {
        let url: URL
        let timeline: String
        let record: String
        let page: Int
    }
    private static let maxBytes = 4 * 1024 * 1024
    private static let maxLines = 40_000
    private static let maxLineBytes = 16 * 1024
    private static let maxPartialBytes = 64 * 1024
    private static let maxStepStarts = 512
    private static let maxListedPages = 4_096

    let jobID: String
    private(set) var lines: [JobStepLine] = []
    /// First-line times of step pages, which mark exactly when each step began writing.
    private(set) var stepStarts: [Date] = []
    private(set) var hasOutput = false
    private(set) var isTruncated = false

    private var timelineID: String?
    private var pageNumber = 1
    private var offset: UInt64 = 0
    private var partial = Data()
    private var discardingLongLine = false
    private var bytes = 0
    private var nextLineID = 0
    private var lastDate: Date?
    private var isGrouped = false
    private var inPrivateKey = false
    private var inspectedStepRecords = Set<String>()
    /// Whether the job page was read to its end after the worker reported every step finished.
    private var readAfterStepsFinished = false
    private var markedUploadedTail = false
    private var secondKey = ""
    private var secondDate: Date?
    private let formatter = ISO8601DateFormatter()

    init(jobID: String) { self.jobID = jobID.lowercased() }

    /// Reads new output from the runner's pages directory, at most `budget` bytes, and returns
    /// whether anything changed. `stepsFinished` says whether the worker log has reported the end
    /// of the job's steps, after which the runner writes nothing more that matters.
    mutating func read(pagesDirectory: URL, budget: Int, stepsFinished: Bool) -> Bool {
        let pages = Self.pageFiles(in: pagesDirectory)
        if timelineID == nil { timelineID = pages.first { $0.record == jobID }?.timeline }
        guard let timelineID else { return false }
        let own = pages.filter { $0.timeline == timelineID }
        let startsChanged = readStepStarts(own.filter { $0.record != jobID && $0.page == 1 })
        let linesChanged = readJobPages(own.filter { $0.record == jobID }.sorted { $0.page < $1.page },
                                        budget: budget, stepsFinished: stepsFinished)
        return startsChanged || linesChanged
    }

    private mutating func readStepStarts(_ pages: [PageFile]) -> Bool {
        var changed = false
        for page in pages where !inspectedStepRecords.contains(page.record) && inspectedStepRecords.count < Self.maxStepStarts {
            guard let handle = try? FileHandle(forReadingFrom: page.url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 128), !data.isEmpty else { continue }
            inspectedStepRecords.insert(page.record)
            if let date = timestamp(in: String(decoding: data, as: UTF8.self))?.date {
                stepStarts.append(date)
                changed = true
            }
        }
        if changed { stepStarts.sort() }
        return changed
    }

    private mutating func readJobPages(_ pages: [PageFile], budget: Int, stepsFinished: Bool) -> Bool {
        var remaining = budget
        var changed = false
        while remaining > 0 {
            guard let current = pages.first(where: { $0.page == pageNumber }) else {
                // Pages before the next one present were uploaded and deleted before they were read in full.
                guard let next = pages.first(where: { $0.page > pageNumber }) else {
                    // The runner uploaded the last page when the job ended. Unless it was read after
                    // the steps finished, lines written since the previous read are lost.
                    if hasOutput && !readAfterStepsFinished && !markedUploadedTail {
                        flushPartial()
                        appendOmission("Output may be missing here: the runner uploaded the rest of this log before RunningMan read it.")
                        markedUploadedTail = true
                        changed = true
                    }
                    break
                }
                flushPartial()
                appendOmission("Output may be missing here: the runner uploaded part of this log before RunningMan read it.")
                pageNumber = next.page; offset = 0; changed = true
                continue
            }
            let isClosed = pages.contains { $0.page > pageNumber }
            guard let handle = try? FileHandle(forReadingFrom: current.url) else { break }
            let requested = min(remaining, 1024 * 1024)
            let data: Data
            do {
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                data = try handle.read(upToCount: requested) ?? Data()
            } catch { break }
            if stepsFinished && !isClosed && data.count < requested { readAfterStepsFinished = true }
            if data.isEmpty {
                // The runner starts a new page only after closing this one, so its end is final.
                guard isClosed else { break }
                flushPartial()
                pageNumber += 1; offset = 0
                continue
            }
            hasOutput = true
            offset += UInt64(data.count)
            remaining -= data.count
            consume(data)
            changed = true
        }
        return changed
    }

    private mutating func consume(_ data: Data) {
        var combined = partial
        combined.append(data)
        var raw: [String] = []
        var start = combined.startIndex
        while let newline = combined[start...].firstIndex(of: 10) {
            if discardingLongLine { discardingLongLine = false }
            else { raw.append(String(decoding: combined[start..<newline], as: UTF8.self)) }
            start = combined.index(after: newline)
        }
        partial = Data(combined[start...])
        // A runaway line must not grow without bound; keep its beginning and skip to the next newline.
        if partial.count > Self.maxPartialBytes {
            if !discardingLongLine { raw.append(String(decoding: partial.prefix(Self.maxPartialBytes), as: UTF8.self)) }
            partial.removeAll()
            discardingLongLine = true
        }
        append(raw)
    }

    private mutating func flushPartial() {
        defer { partial.removeAll(); discardingLongLine = false }
        guard !partial.isEmpty, !discardingLongLine else { return }
        append([String(decoding: partial, as: UTF8.self)])
    }

    private mutating func append(_ rawLines: [String]) {
        var pending: [(date: Date, text: String, kind: JobStepLine.Kind, grouped: Bool)] = []
        for rawLine in rawLines {
            var text = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let stamped = timestamp(in: text) {
                lastDate = stamped.date
                text = stamped.rest
            }
            let date = lastDate ?? Date(timeIntervalSince1970: 0)
            if text.contains("-----BEGIN ") && text.contains("PRIVATE KEY-----") {
                if !inPrivateKey { pending.append((date, "Private key omitted from the job log.", .omission, isGrouped)) }
                inPrivateKey = !text.contains("-----END ")
                continue
            }
            if inPrivateKey {
                if text.contains("-----END ") && text.contains("PRIVATE KEY-----") { inPrivateKey = false }
                continue
            }
            guard let classified = classify(text) else { continue }
            pending.append((date, classified.text, classified.kind, classified.grouped))
        }
        guard !pending.isEmpty else { return }
        let redacted = Self.redact(pending.map(\.text))
        for (index, item) in pending.enumerated() {
            let text = Self.limit(redacted[index])
            lines.append(JobStepLine(id: nextLineID, date: item.date, text: text, kind: item.kind, isGrouped: item.grouped))
            nextLineID += 1
            bytes += text.utf8.count + 1
        }
        trim()
    }

    private mutating func appendOmission(_ text: String) {
        isTruncated = true
        lines.append(JobStepLine(id: nextLineID, date: lastDate ?? Date(timeIntervalSince1970: 0), text: text, kind: .omission))
        nextLineID += 1
        bytes += text.utf8.count + 1
        trim()
    }

    private mutating func trim() {
        guard bytes > Self.maxBytes || lines.count > Self.maxLines else { return }
        // Drop a quarter at a time so trimming stays amortized.
        var dropped = 0
        while dropped < lines.count && (bytes > Self.maxBytes * 3 / 4 || lines.count - dropped > Self.maxLines * 3 / 4) {
            bytes -= lines[dropped].text.utf8.count + 1
            dropped += 1
        }
        lines.removeFirst(dropped)
        isTruncated = true
    }

    private mutating func classify(_ text: String) -> (text: String, kind: JobStepLine.Kind, grouped: Bool)? {
        if text.hasPrefix("##[group]") {
            isGrouped = true
            return (String(text.dropFirst("##[group]".count)), .groupHeader, false)
        }
        if text.hasPrefix("##[endgroup]") {
            isGrouped = false
            return nil
        }
        let markers: [(String, JobStepLine.Kind)] = [("##[error]", .error), ("##[warning]", .warning), ("##[notice]", .notice),
            ("##[debug]", .debug), ("##[command]", .command), ("##[section]", .section)]
        for (marker, kind) in markers where text.hasPrefix(marker) {
            return (String(text.dropFirst(marker.count)), kind, isGrouped)
        }
        return (text, .output, isGrouped)
    }

    /// Splits `2026-10-17T12:00:00.1234567Z text` into its date and text.
    private mutating func timestamp(in line: String) -> (date: Date, rest: String)? {
        let utf8 = Array(line.utf8.prefix(40))
        guard utf8.count >= 20, utf8[4] == 45, utf8[7] == 45, utf8[10] == 84, utf8[13] == 58, utf8[16] == 58,
              let zone = utf8.firstIndex(of: 90), zone >= 19 else { return nil }
        let key = String(decoding: utf8[0..<19], as: UTF8.self)
        if key != secondKey {
            secondKey = key
            secondDate = formatter.date(from: key + "Z")
        }
        guard var date = secondDate else { return nil }
        if zone > 20, utf8[19] == 46 {
            let digits = utf8[20..<zone]
            guard digits.allSatisfy({ (48...57).contains($0) }),
                  let fraction = Double("0." + String(decoding: digits, as: UTF8.self)) else { return nil }
            date += fraction
        } else if zone != 19 { return nil }
        let restStart = zone + 1 < utf8.count && utf8[zone + 1] == 32 ? zone + 2 : zone + 1
        let rest = String(decoding: line.utf8.dropFirst(restStart), as: UTF8.self)
        return (date, rest)
    }

    private static func pageFiles(in directory: URL) -> [PageFile] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.prefix(maxListedPages).compactMap { url in
            // Only plain files named by the runner; a symbolic link is never followed.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.pathExtension == "log" else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.lowercased().split(separator: "_")
            guard parts.count == 3, isGUID(parts[0]), isGUID(parts[1]),
                  let page = Int(parts[2]), (1...100_000).contains(page) else { return nil }
            return PageFile(url: url, timeline: String(parts[0]), record: String(parts[1]), page: page)
        }
    }

    private static func isGUID(_ text: Substring) -> Bool {
        text.utf8.count == 36 && text.utf8.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == 45 : (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    /// Redacts a batch at once; the redactor is line-preserving for these inputs, but fall back to
    /// per-line redaction if a replacement ever changes the line count.
    private static func redact(_ texts: [String]) -> [String] {
        let joined = SecretRedactor.redact(texts.joined(separator: "\n"))
        let split = joined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return split.count == texts.count ? split : texts.map(SecretRedactor.redact)
    }

    private static func limit(_ text: String) -> String {
        guard text.utf8.count > maxLineBytes else { return text }
        var prefix = Array(text.utf8.prefix(maxLineBytes))
        while !prefix.isEmpty {
            if let valid = String(bytes: prefix, encoding: .utf8) { return valid + " …" }
            prefix.removeLast()
        }
        return ""
    }
}

/// Splits a job's output into its steps. Pure, so the boundary rules can be tested directly.
enum JobStepAssembler {
    static func steps(entries: [JobStepTimeline.Entry], lines: [JobStepLine], stepStarts: [Date], isFinished: Bool) -> [JobStep] {
        let bounds = boundaries(entries: entries, lines: lines, stepStarts: stepStarts)
        var buckets = Array(repeating: [JobStepLine](), count: entries.count)
        let ordered = bounds.enumerated().compactMap { index, bound in bound.map { (index, $0) } }
        var position = 0
        for line in lines {
            while position + 1 < ordered.count && ordered[position + 1].1 <= line.date { position += 1 }
            guard !ordered.isEmpty else { break }
            buckets[ordered[position].0].append(line)
        }
        return entries.enumerated().map { index, entry in
            let outcome = isFinished && entry.outcome == .running ? JobStepOutcome.unknown : entry.outcome
            // Set up job's bound is open-ended; its start is the worker's job start.
            let start = index == 0 ? entry.startedAt : bounds[index] ?? entry.startedAt
            return JobStep(id: index, name: entry.name, startedAt: start,
                           finishedAt: entry.finishedAt, outcome: outcome, lines: buckets[index])
        }
    }

    /// The time each step began writing, or nil for skipped steps, which write nothing.
    ///
    /// The worker log only has whole seconds, so a step that started at 12:00:05.4 is logged as
    /// 12:00:05. The precise start is the first line of a step page in that second, or else the
    /// first `##[group]` header in that second, which is how most steps begin. Looking only within
    /// the logged second keeps a later step's page from claiming an earlier step's boundary, and a
    /// start must come after the previous step's, so steps starting in the same second each keep
    /// their own. When the first of those writes nothing, it takes the second's start, the second
    /// falls back to the same bound, and the later step receives the lines.
    static func boundaries(entries: [JobStepTimeline.Entry], lines: [JobStepLine], stepStarts: [Date]) -> [Date?] {
        var bounds = [Date?](repeating: nil, count: entries.count)
        guard !entries.isEmpty else { return bounds }
        bounds[0] = .distantPast
        var previous = Date.distantPast
        for index in entries.indices where index > 0 && entries[index].outcome != .skipped {
            let second = entries[index].startedAt
            let lower = max(second, previous)
            let upper = second.addingTimeInterval(1)
            let bound = stepStarts.first { $0 >= lower && $0 > previous && $0 < upper }
                ?? firstGroupHeader(in: lines, from: lower, after: previous, before: upper)
                ?? lower
            bounds[index] = bound
            previous = bound
        }
        return bounds
    }

    /// Lines are in write order, so their timestamps only grow and a binary search finds the second.
    private static func firstGroupHeader(in lines: [JobStepLine], from lower: Date, after previous: Date, before upper: Date) -> Date? {
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].date < lower { low = middle + 1 } else { high = middle }
        }
        while low < lines.count && lines[low].date < upper {
            if lines[low].kind == .groupHeader && lines[low].date > previous { return lines[low].date }
            low += 1
        }
        return nil
    }
}
