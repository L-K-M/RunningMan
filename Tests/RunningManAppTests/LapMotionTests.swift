import XCTest
import RunningManCore
@testable import RunningMan

/// The track's events: what it calls out with a sound or a glint must match what happened.
final class LapMotionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func reference(_ pace: GhostPace = .usual, build: Double = 50) -> LapReference {
        let laps = (0..<3).map { run in
            LapRecord(jobID: "lap-\(run)", finishedAt: start.addingTimeInterval(-Double(3 - run) * 1_000), outcome: .success,
                      seconds: 3 + build + 20, splits: [LapSplit(name: "Set up job", seconds: 3, outcome: .success),
                                                       LapSplit(name: "Build", seconds: build, outcome: .success),
                                                       LapSplit(name: "Test", seconds: 20, outcome: .success)])
        }
        return LapReference.make(from: laps, pace: pace)!
    }

    /// A slow set-up leaves the runner 13 s behind; the build then finishes 25 s early at 41 s.
    private func steps(at now: Double) -> [JobStep] {
        var steps = [JobStep(id: 0, name: "Set up job", startedAt: start, finishedAt: start.addingTimeInterval(16), outcome: .success, lines: [])]
        let buildDone = now >= 41
        steps.append(JobStep(id: 1, name: "Build", startedAt: start.addingTimeInterval(16), finishedAt: buildDone ? start.addingTimeInterval(41) : nil,
                             outcome: buildDone ? .success : .running, lines: []))
        if buildDone {
            steps.append(JobStep(id: 2, name: "Test", startedAt: start.addingTimeInterval(41), finishedAt: nil, outcome: .running, lines: []))
        }
        return steps
    }

    private func frame(_ motion: LapMotion, at seconds: Double, reference: LapReference, steps: [JobStep], finished: Bool = false,
                       outcome: JobOutcome = .running) -> [LapEvent] {
        let now = start.addingTimeInterval(seconds)
        let progress = LapProgress.make(steps: steps, reference: reference, jobStarted: start, isFinished: finished, jobOutcome: outcome, now: now)
        return motion.update(progress, jobID: "job", now: now, reduceMotion: false,
                             layout: LapTrack.layout(progress: progress, width: 600, style: .full))
    }

    func testAPassIsCalledOutOnceEvenWhileTheSpringStillGlides() {
        let motion = LapMotion()
        let reference = reference()
        var events: [LapEvent] = []
        for frameIndex in 0...120 {
            let seconds = 40 + Double(frameIndex) / 60
            events += frame(motion, at: seconds, reference: reference, steps: steps(at: seconds))
        }
        XCTAssertEqual(events.filter { $0 == .overtake }.count, 1)
        XCTAssertNotNil(motion.passedAt)
    }

    func testCatchingAGhostParkedAtTheFinishIsNoPass() {
        let motion = LapMotion()
        let reference = reference(build: 20)  // 43 s
        func run(finished: Bool) -> [JobStep] {
            [JobStep(id: 0, name: "Set up job", startedAt: start, finishedAt: start.addingTimeInterval(3), outcome: .success, lines: []),
             JobStep(id: 1, name: "Build", startedAt: start.addingTimeInterval(3), finishedAt: start.addingTimeInterval(60), outcome: .success, lines: []),
             JobStep(id: 2, name: "Test", startedAt: start.addingTimeInterval(60), finishedAt: finished ? start.addingTimeInterval(90) : nil,
                     outcome: finished ? .success : .running, lines: [])]
        }
        // Far behind while the ghost waits at the line, then over the line itself at 90 s.
        var events = frame(motion, at: 70, reference: reference, steps: run(finished: false))
        events += frame(motion, at: 90.1, reference: reference, steps: run(finished: true), finished: true, outcome: .success)
        XCTAssertFalse(events.contains(.overtake), "Level with a parked ghost is not overtaking it")
        XCTAssertTrue(events.contains(.finished(.success)))
    }

    func testSwitchingTheGhostIsSilent() {
        let motion = LapMotion()
        let behindBy = reference(build: 50)
        // A slower earlier run puts the same runner ahead of its ghost.
        let slower = LapReference.make(from: (0..<2).map { run in
            LapRecord(jobID: "slow-\(run)", finishedAt: start.addingTimeInterval(Double(run)), outcome: .success, seconds: 103,
                      splits: [LapSplit(name: "Set up job", seconds: 18, outcome: .success), LapSplit(name: "Lint", seconds: 5, outcome: .success),
                               LapSplit(name: "Build", seconds: 60, outcome: .success), LapSplit(name: "Test", seconds: 20, outcome: .success)])
        }, pace: .usual)!
        var events = frame(motion, at: 30, reference: behindBy, steps: steps(at: 30))
        for frameIndex in 1...30 {
            events += frame(motion, at: 30 + Double(frameIndex) / 60, reference: slower, steps: steps(at: 30))
        }
        XCTAssertTrue(events.isEmpty, "\(events)")
    }

    func testAFinishedTrackSettlesAndStopsAskingForFrames() {
        let motion = LapMotion()
        let reference = reference()
        var finished = steps(at: 50)
        finished[2] = JobStep(id: 2, name: "Test", startedAt: start.addingTimeInterval(41), finishedAt: start.addingTimeInterval(60),
                              outcome: .success, lines: [])
        _ = frame(motion, at: 59, reference: reference, steps: steps(at: 59))
        XCTAssertFalse(motion.isSettled(at: start.addingTimeInterval(59)))
        _ = frame(motion, at: 60.1, reference: reference, steps: finished, finished: true, outcome: .success)
        XCTAssertFalse(motion.isSettled(at: start.addingTimeInterval(60.2)), "The finish plays first")
        for frameIndex in 1...240 {
            _ = frame(motion, at: 60.1 + Double(frameIndex) / 60, reference: reference, steps: finished, finished: true, outcome: .success)
        }
        XCTAssertTrue(motion.isSettled(at: start.addingTimeInterval(64.2)))
    }

    func testARunLevelWithItsGhostIsNoPassWhenAStepEndsOnTime() {
        let motion = LapMotion()
        let reference = reference()  // 3, 50, 20
        func run(buildDone: Bool) -> [JobStep] {
            [JobStep(id: 0, name: "Set up job", startedAt: start, finishedAt: start.addingTimeInterval(3), outcome: .success, lines: []),
             JobStep(id: 1, name: "Build", startedAt: start.addingTimeInterval(3), finishedAt: buildDone ? start.addingTimeInterval(52.8) : nil,
                     outcome: buildDone ? .success : .running, lines: [])]
                + (buildDone ? [JobStep(id: 2, name: "Test", startedAt: start.addingTimeInterval(52.8), finishedAt: nil, outcome: .running, lines: [])] : [])
        }
        // The figure waits at 98% of the build while the readout stays level; the build ends on time.
        var events: [LapEvent] = []
        for frameIndex in 0...40 {
            let seconds = 50 + Double(frameIndex) / 8
            events += frame(motion, at: seconds, reference: reference, steps: run(buildDone: seconds >= 52.8))
        }
        XCTAssertFalse(events.contains(.overtake), "Nothing passed: the readout never left level")
    }

    func testAFailedJobStillCleaningUpKeepsDrawingItsGhost() {
        let motion = LapMotion()
        let reference = reference()
        let failing = [JobStep(id: 0, name: "Set up job", startedAt: start, finishedAt: start.addingTimeInterval(3), outcome: .success, lines: []),
                       JobStep(id: 1, name: "Build", startedAt: start.addingTimeInterval(3), finishedAt: start.addingTimeInterval(20), outcome: .failure, lines: []),
                       JobStep(id: 2, name: "Upload logs", startedAt: start.addingTimeInterval(20), finishedAt: nil, outcome: .running, lines: [])]
        for frameIndex in 0...80 {
            _ = frame(motion, at: 20 + Double(frameIndex) / 8, reference: reference, steps: failing)
        }
        XCTAssertFalse(motion.isSettled(at: start.addingTimeInterval(30)), "The ghost still runs until the job ends")
    }
}
