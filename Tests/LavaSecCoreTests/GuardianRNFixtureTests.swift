import Foundation
import XCTest
import LavaSecKit
import LavaSecPresentation

/// Both renderers consume these samples. Swift validates the committed fixture
/// against its authored plans; Jest validates the shared RN equations against it.
final class GuardianRNFixtureTests: XCTestCase {
    private struct Sample: Codable {
        let from: String
        let to: String
        let kind: String
        let elapsed: Double
        let duration: Double
        let frame: [String: Double]
    }
    private func fields(_ f: GuardianMascotFrame) -> [String: Double] {
        ["shieldWakeAmount": f.shieldWakeAmount, "shieldScale": f.shieldScale,
         "glowAmount": f.glowAmount, "sleepyEyeAmount": f.sleepyEyeAmount,
         "leftEyeOpenAmount": f.leftEyeOpenAmount, "rightEyeOpenAmount": f.rightEyeOpenAmount,
         "winkAmount": f.winkAmount, "happyEyeAmount": f.happyEyeAmount,
         "concernAmount": f.concernAmount, "gratitudeAmount": f.gratitudeAmount,
         "mouthCurve": f.mouthCurve, "pauseAmount": f.pauseAmount]
    }
    func testSharedFramesMatchEveryNativeTransitionAndBlinkBoundary() throws {
        let states: [GuardianMascotState] = [.sleeping, .waking, .awake, .paused, .retrying, .concerned, .grateful]
        var expected: [Sample] = []
        for from in states {
            for to in states {
                let plan = GuardianMascotAnimationPlan.animation(from: from, to: to)
                for elapsed in [-0.1, 0, plan.duration * 0.12, plan.duration * 0.34,
                                plan.duration * 0.45, plan.duration * 0.78, plan.duration,
                                plan.duration + 0.1] {
                    expected.append(Sample(from: from.rawValue, to: to.rawValue, kind: "transition",
                        elapsed: elapsed, duration: plan.duration, frame: fields(plan.frame(at: elapsed))))
                }
            }
            let blink = GuardianMascotAnimationPlan.blink(on: from)
            for elapsed in [0, 0.0552, 0.207, 0.3588, 0.46, 0.6] {
                expected.append(Sample(from: from.rawValue, to: from.rawValue, kind: "blink",
                    elapsed: elapsed, duration: blink.duration, frame: fields(blink.frame(at: elapsed))))
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("ReactNative/tests/fixtures/guardian-frames.json")
        if ProcessInfo.processInfo.environment["LAVA_UPDATE_GUARDIAN_FIXTURE"] == "1" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let rows = try expected.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            try Data(("[\n" + rows.joined(separator: ",\n") + "\n]\n").utf8).write(to: file, options: .atomic)
        }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: file))
        XCTAssertEqual(samples.count, 434)
        XCTAssertEqual(samples.count, expected.count)
        for (actual, native) in zip(samples, expected) {
            XCTAssertEqual(actual.from, native.from); XCTAssertEqual(actual.to, native.to)
            XCTAssertEqual(actual.kind, native.kind); XCTAssertEqual(actual.elapsed, native.elapsed, accuracy: 1e-12)
            XCTAssertEqual(actual.duration, native.duration, accuracy: 1e-12)
            XCTAssertEqual(Set(actual.frame.keys), Set(native.frame.keys))
            for (key, value) in native.frame {
                XCTAssertEqual(try XCTUnwrap(actual.frame[key]), value, accuracy: 1e-12,
                    "\(actual.from) → \(actual.to) \(actual.elapsed): \(key)")
            }
        }
    }
}
