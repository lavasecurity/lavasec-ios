import AVFoundation
import CryptoKit
import UIKit

/// Offline, caption-matched narration. An unapproved, absent or damaged asset
/// leaves the caller on the public system-speech fallback.
@objc(LavaBundledNarrationPlayer)
@MainActor final class BundledNarrationPlayer: NSObject, AVAudioPlayerDelegate {
    private static let shared = BundledNarrationPlayer()
    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?

    @objc static func play(text: String, locale: String, completion: @escaping (Bool) -> Void) -> Bool {
        shared.start(text: text, locale: locale, completion: completion)
    }
    @objc static func stop() { shared.finish(false) }

    private func start(text: String, locale: String, completion: @escaping (Bool) -> Void) -> Bool {
        finish(false)
        guard UIApplication.shared.applicationState == .active,
              let manifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "ExploreNarration"),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["schemaVersion"] as? Int == 1,
              manifest["listeningQualified"] as? Bool == true,
              let clips = manifest["clips"] as? [[String: Any]],
              let clip = clips.first(where: { $0["text"] as? String == text && $0["locale"] as? String == locale && $0["approved"] as? Bool == true }),
              let file = clip["file"] as? String, file == (file as NSString).lastPathComponent,
              file.hasSuffix(".caf") || file.hasSuffix(".m4a"), let checksum = clip["sha256"] as? String,
              let audio = try? Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(file)),
              SHA256.hash(data: audio).map({ String(format: "%02x", $0) }).joined() == checksum,
              let candidate = try? AVAudioPlayer(data: audio), candidate.duration > 0, candidate.duration <= 30 else { return false }
        player = candidate
        self.completion = completion
        candidate.delegate = self
        guard candidate.play() else { player = nil; self.completion = nil; return false }
        Task { @MainActor [weak self, weak candidate] in
            try? await Task.sleep(for: .seconds(31))
            guard let self, let candidate, self.player === candidate else { return }
            self.finish(false)
        }
        return true
    }
    private func finish(_ success: Bool) {
        let callback = completion
        completion = nil
        player?.stop()
        player = nil
        callback?(success)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.finish(flag)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
