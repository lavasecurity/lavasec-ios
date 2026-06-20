import XCTest

final class PublicNetworkActivityFeatureTests: XCTestCase {
    func testNetworkActivityControlsAreNotQAGated() throws {
        let settingsSource = try readSource("LavaSecApp/SettingsView.swift")

        assertPhraseNotInsideQAConditional("Toggle(\"Keep local network activity\"", in: settingsSource)
        assertPhraseNotInsideQAConditional("localLogClearButton(.networkActivity)", in: settingsSource)
        assertPhraseNotInsideQAConditional("network activity can be kept", in: settingsSource)
    }

    func testNetworkActivityLogViewIsNotQAGated() throws {
        let diagnosticsSource = try readSource("LavaSecApp/DiagnosticsView.swift")

        assertPhraseNotInsideQAConditional(".localLogSubpageChrome(", in: diagnosticsSource)
        assertPhraseNotInsideQAConditional("struct NetworkActivityLogView", in: diagnosticsSource)
    }

    func testNetworkActivityLoggingIsNotQAGated() throws {
        let appViewModelSource = try readSource("LavaSecApp/AppViewModel.swift")
        let tunnelSource = try readSource("LavaSecTunnel/PacketTunnelProvider.swift")

        assertPhraseNotInsideQAConditional("logSettings.append(configuration.keepNetworkActivity)", in: appViewModelSource)
        assertPhraseNotInsideQAConditional("guard configuration.keepNetworkActivity else", in: appViewModelSource)
        assertPhraseNotInsideQAConditional("guard configuration.keepNetworkActivity else", in: tunnelSource)
        assertPhraseNotInsideQAConditional("event: .reconnectNeeded(reason: health.lastFailureReason", in: tunnelSource)
    }

    private func readSource(_ relativePath: String) throws -> String {
        let sourceURL = packageRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertPhraseNotInsideQAConditional(
        _ phrase: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var conditionalStack: [Bool] = []

        for (lineOffset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineText = String(rawLine)
            let trimmedLine = lineText.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("#if") {
                conditionalStack.append(trimmedLine.contains("LAVA_QA_TOOLS"))
            } else if trimmedLine.hasPrefix("#else") || trimmedLine.hasPrefix("#elseif") {
                if conditionalStack.popLast() != nil {
                    conditionalStack.append(false)
                }
            } else if trimmedLine.hasPrefix("#endif") {
                _ = conditionalStack.popLast()
            }

            guard lineText.contains(phrase), conditionalStack.contains(true) else {
                continue
            }

            XCTFail(
                "\"\(phrase)\" is still gated by LAVA_QA_TOOLS at line \(lineOffset + 1).",
                file: file,
                line: line
            )
        }
    }
}
