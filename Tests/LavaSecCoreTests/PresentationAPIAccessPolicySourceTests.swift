import Foundation
import XCTest

final class PresentationAPIAccessPolicySourceTests: XCTestCase {
    func testGuardianMascotDeclarationsMatchAuditedAccessLedger() throws {
        let source = try readSource(.guardianMascotAnimation)
        let frameBlock = try sourceBlock(
            in: source,
            startingAt: "public struct GuardianMascotFrame: Equatable, Sendable {",
            endingBefore: "public struct GuardianMascotAnimationPlan: Equatable, Sendable {"
        )
        let planBlock = try sourceBlock(
            in: source,
            startingAt: "public struct GuardianMascotAnimationPlan: Equatable, Sendable {",
            endingBefore: "private func interpolate("
        )

        XCTAssertEqual(
            accessQualifiedDeclarationLines(in: frameBlock),
            [
                "public struct GuardianMascotFrame: Equatable, Sendable {",
                "public let shieldWakeAmount: Double",
                "public let shieldScale: Double",
                "public let glowAmount: Double",
                "public let sleepyEyeAmount: Double",
                "public let leftEyeOpenAmount: Double",
                "public let rightEyeOpenAmount: Double",
                "public let winkAmount: Double",
                "public let happyEyeAmount: Double",
                "public let concernAmount: Double",
                "package let pauseAmount: Double",
                "public let gratitudeAmount: Double",
                "public let mouthCurve: Double",
                "internal init(",
            ]
        )
        XCTAssertEqual(
            accessQualifiedDeclarationLines(in: planBlock),
            [
                "public struct GuardianMascotAnimationPlan: Equatable, Sendable {",
                "package static let sleepWakeDuration = 0.82",
                "internal static let blinkDelayDuration = 0.5",
                "package static let blinkDuration = 0.46",
                "public static let wakeDuration = sleepWakeDuration + blinkDelayDuration + blinkDuration",
                "internal static let sleepDuration = sleepWakeDuration",
                "public static let stateChangeDuration = 0.44",
                "internal static let settleDuration = 0.22",
                "package let startState: GuardianMascotState",
                "public let endState: GuardianMascotState",
                "public let duration: Double",
                "package static func transition(",
                "public static func blink(",
                "package static func hold(",
                "package static func sequence(",
                "public static func animation(",
                "package static func stableFrame(for state: GuardianMascotState) -> GuardianMascotFrame {",
                "public func frame(at elapsed: Double) -> GuardianMascotFrame {",
            ]
        )
    }

    func testRetainedPublicGuardianMascotDeclarationsHaveAttachedDocumentation() throws {
        let source = try readSource(.guardianMascotAnimation)
        let declarationLines = [
            "public struct GuardianMascotFrame: Equatable, Sendable {",
            "public let shieldWakeAmount: Double",
            "public let shieldScale: Double",
            "public let glowAmount: Double",
            "public let sleepyEyeAmount: Double",
            "public let leftEyeOpenAmount: Double",
            "public let rightEyeOpenAmount: Double",
            "public let winkAmount: Double",
            "public let happyEyeAmount: Double",
            "public let concernAmount: Double",
            "public let gratitudeAmount: Double",
            "public let mouthCurve: Double",
            "public struct GuardianMascotAnimationPlan: Equatable, Sendable {",
            "public static let wakeDuration = sleepWakeDuration + blinkDelayDuration + blinkDuration",
            "public static let stateChangeDuration = 0.44",
            "public let endState: GuardianMascotState",
            "public let duration: Double",
            "public static func blink(",
            "public static func animation(",
            "public func frame(at elapsed: Double) -> GuardianMascotFrame {",
        ]

        XCTAssertEqual(declarationLines.count, 20)
        let sourceLines = source.components(separatedBy: .newlines)
        for declarationLine in declarationLines {
            let matchingLineIndices = sourceLines.indices.filter {
                sourceLines[$0].trimmingCharacters(in: .whitespaces) == declarationLine
            }
            XCTAssertEqual(
                matchingLineIndices.count,
                1,
                "expected one exact declaration line: \(declarationLine)"
            )

            guard let declarationLineIndex = matchingLineIndices.first, declarationLineIndex > 0 else {
                continue
            }
            XCTAssertTrue(
                sourceLines[declarationLineIndex - 1]
                    .trimmingCharacters(in: .whitespaces)
                    .hasPrefix("///"),
                "expected attached /// documentation for: \(declarationLine)"
            )
        }
    }

    private func accessQualifiedDeclarationLines(in block: String) -> [String] {
        block.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.hasPrefix("public ")
                    || $0.hasPrefix("package ")
                    || $0.hasPrefix("internal ")
            }
    }
}
