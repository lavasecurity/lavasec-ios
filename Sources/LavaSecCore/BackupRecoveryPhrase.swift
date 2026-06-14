import Foundation
import Security

public enum BackupRecoveryPhrase {
    public static let wordCount = 8
    private static let consonants = Array("bcdfghjklmnprstv")
    private static let vowels = Array("aeiouy")

    public static func generate() throws -> String {
        try (0..<wordCount)
            .map { _ in try generateToken() }
            .joined(separator: " ")
    }

    public static func words(from value: String) -> [String] {
        let withoutNumbers = value.replacingOccurrences(
            of: #"\b\d{1,2}[\.)]"#,
            with: " ",
            options: .regularExpression
        )
        let separated = withoutNumbers.replacingOccurrences(
            of: #"[-_,;:\n\r\t]+"#,
            with: " ",
            options: .regularExpression
        )
        let collapsed = separated.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return collapsed
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { normalizedWord(String($0)) }
    }

    public static func fillSlots(from value: String, count: Int = wordCount) -> [String] {
        let parsedWords = words(from: value)
        return (0..<count).map { index in
            guard index < parsedWords.count else {
                return ""
            }

            return parsedWords[index]
        }
    }

    public static func phrase(from words: [String]) -> String {
        words
            .map(normalizedWord)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func normalizedWord(_ word: String) -> String {
        word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func generateToken() throws -> String {
        let characters: [Character] = [
            consonants[try randomIndex(upperBound: consonants.count)],
            vowels[try randomIndex(upperBound: vowels.count)],
            consonants[try randomIndex(upperBound: consonants.count)],
            vowels[try randomIndex(upperBound: vowels.count)]
        ]

        return String(characters)
    }

    private static func randomIndex(upperBound: Int) throws -> Int {
        precondition(upperBound > 0)

        let bound = UInt32(upperBound)
        let limit = UInt32.max - (UInt32.max % bound)

        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { bytes in
                SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, bytes.baseAddress!)
            }

            guard status == errSecSuccess else {
                throw ZeroKnowledgeBackupEnvelopeError.randomBytesFailed(status)
            }

            if value < limit {
                return Int(value % bound)
            }
        }
    }
}

public enum BackupDeviceSecret {
    public static func generate(byteCount: Int = 32) throws -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
        }

        guard status == errSecSuccess else {
            throw ZeroKnowledgeBackupEnvelopeError.randomBytesFailed(status)
        }

        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
