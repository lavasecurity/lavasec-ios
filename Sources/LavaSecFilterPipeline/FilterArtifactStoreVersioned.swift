import Foundation
import LavaSecKit

/// Pointer written at the root of the content-addressed artifact area
/// (`filter-artifacts/current.json`). Its atomic rename is the single publish event
/// for a whole versioned directory: a reader sees either the old token (an old,
/// complete dir) or the new token (a new, complete dir) — never a torn set. This is
/// the substrate that makes the artifact trio atomic to the lock-free, `mmap`-based
/// tunnel reader (LAV-90 Phase 1).
public struct FilterArtifactPointer: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    /// Content-addressed directory token selected by this pointer.
    public let token: String
    package let snapshotIdentityFingerprint: String
    package let generatedAt: Date
    package let writtenAt: Date

    package init(
        token: String,
        snapshotIdentityFingerprint: String,
        generatedAt: Date,
        writtenAt: Date,
        schemaVersion: Int = FilterArtifactPointer.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.snapshotIdentityFingerprint = snapshotIdentityFingerprint
        self.generatedAt = generatedAt
        self.writtenAt = writtenAt
    }
}

extension FilterArtifactStore {
    /// Default name of the content-addressed artifact directory.
    public static let defaultArtifactsDirectoryName = "filter-artifacts"
    /// Default filename of the atomically published artifact pointer.
    public static let defaultArtifactPointerFilename = "current.json"

    /// Content-addressed token for a snapshot: its identity fingerprint plus the
    /// snapshot's `generatedAt` (ms) so two publishes with identical identity but
    /// different generation still get distinct, immutable directories.
    public static func versionedToken(for preparedSnapshot: PreparedFilterSnapshot) -> String {
        let millis = Int((preparedSnapshot.snapshot.generatedAt.timeIntervalSince1970 * 1000).rounded())
        return "\(preparedSnapshot.identity.fingerprint)-\(millis)"
    }

    package func artifactsRootURL(
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName
    ) -> URL {
        directoryURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    package func artifactPointerURL(
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) -> URL {
        artifactsRootURL(directoryName: directoryName).appendingPathComponent(pointerFilename)
    }

    /// Returns the directory URL for a content-addressed artifact token.
    public func versionedDirectoryURL(
        token: String,
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName
    ) -> URL {
        artifactsRootURL(directoryName: directoryName).appendingPathComponent(token, isDirectory: true)
    }

    private func versionedStore(token: String, directoryName: String) -> FilterArtifactStore {
        FilterArtifactStore(
            directoryURL: versionedDirectoryURL(token: token, directoryName: directoryName),
            manifestFilename: manifestFilename,
            preparedSnapshotFilename: preparedSnapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename
        )
    }

    /// Stage the prepared/compact/manifest trio into a fresh content-addressed
    /// directory (manifest LAST, each `.atomic`) WITHOUT flipping the pointer, and
    /// return the pointer that would publish it. Safe to run off-lock: the directory
    /// is not yet pointed-to, so it is invisible to readers. The caller flips the
    /// pointer (`writeArtifactPointer`) under the publish lock — that flip is the
    /// linearization point.
    package func stageVersionedArtifacts(
        preparedSnapshot: PreparedFilterSnapshot,
        writtenAt: Date,
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName
    ) throws -> FilterArtifactPointer {
        let token = Self.versionedToken(for: preparedSnapshot)
        let pointer = FilterArtifactPointer(
            token: token,
            snapshotIdentityFingerprint: preparedSnapshot.identity.fingerprint,
            generatedAt: preparedSnapshot.snapshot.generatedAt,
            writtenAt: writtenAt
        )

        // Content-addressed immutability: the token is identity-fingerprint +
        // generatedAt, so an existing, complete token directory already holds
        // identical bytes. NEVER rewrite it in place — the pointer may already name
        // this directory and a lock-free reader may be mid-read; an in-place rewrite
        // would expose a torn trio (a new prepared/compact paired with the old
        // manifest). A loadable manifest (written LAST) means the directory is
        // complete, so staging is a no-op that returns the same pointer.
        let versioned = versionedStore(token: token, directoryName: directoryName)
        if ((try? versioned.loadManifest()) ?? nil) != nil {
            return pointer
        }

        try versioned.persist(preparedSnapshot: preparedSnapshot, writtenAt: writtenAt)
        return pointer
    }

    /// Stage a versioned directory and atomically flip the pointer to it in one call.
    /// Convenience for callers that own no external lock (e.g. tests); the production
    /// writer stages off-lock then flips `writeArtifactPointer` under the publish lock.
    @discardableResult
    package func persistVersioned(
        preparedSnapshot: PreparedFilterSnapshot,
        writtenAt: Date,
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) throws -> FilterArtifactPointer {
        let pointer = try stageVersionedArtifacts(
            preparedSnapshot: preparedSnapshot,
            writtenAt: writtenAt,
            directoryName: directoryName
        )
        try writeArtifactPointer(pointer, directoryName: directoryName, pointerFilename: pointerFilename)
        return pointer
    }

    /// Atomically (re)writes the pointer file. This is the single publish event for
    /// the directory it names.
    package func writeArtifactPointer(
        _ pointer: FilterArtifactPointer,
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) throws {
        try FileManager.default.createDirectory(
            at: artifactsRootURL(directoryName: directoryName),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pointer)
        try data.write(
            to: artifactPointerURL(directoryName: directoryName, pointerFilename: pointerFilename),
            options: [.atomic]
        )
    }

    /// Loads the current artifact pointer, returning `nil` when it is absent or invalid.
    public func loadArtifactPointer(
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) -> FilterArtifactPointer? {
        guard let data = try? Data(
            contentsOf: artifactPointerURL(directoryName: directoryName, pointerFilename: pointerFilename)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(FilterArtifactPointer.self, from: data)
    }

    /// Resolve the current pointer to a store scoped at its versioned directory, or
    /// `nil` if there is no pointer or the directory is missing. This is the seam the
    /// (lock-free) tunnel reader will adopt at the Task-6 cutover.
    package func currentVersionedStore(
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) -> FilterArtifactStore? {
        guard let pointer = loadArtifactPointer(
            directoryName: directoryName,
            pointerFilename: pointerFilename
        ) else {
            return nil
        }
        let store = versionedStore(token: pointer.token, directoryName: directoryName)
        guard FileManager.default.fileExists(atPath: store.directoryURL.path) else {
            return nil
        }
        return store
    }

    /// The store to READ artifacts from: the pointer-resolved versioned store when a
    /// pointer is published, else this (legacy root) store. Lets readers adopt the
    /// atomic pointer-swapped set while staying safe before the first versioned
    /// publish and on a rollback. Resolve ONCE per read pass and reuse it, so a reader
    /// never pairs a pointer from one generation with files from another.
    public func readableStore(
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        pointerFilename: String = FilterArtifactStore.defaultArtifactPointerFilename
    ) -> FilterArtifactStore {
        currentVersionedStore(directoryName: directoryName, pointerFilename: pointerFilename) ?? self
    }

    /// Grace window protecting a freshly-staged-but-not-yet-pointed-to directory from a
    /// peer writer's GC. Must comfortably exceed the time between staging (off-lock,
    /// including the snapshot encode) and the pointer flip, so a second (background)
    /// writer's in-flight token is never reaped out from under it.
    package static let versionedGarbageGraceInterval: TimeInterval = 120

    /// Grace window for WARM-dir GC (`collectWarmArtifactGarbage`), deliberately much longer
    /// than `versionedGarbageGraceInterval`: warm GC's only job is reclaiming superseded warm
    /// directories, where promptness is worthless. A same-filter republish overwrites
    /// `lastCompiledToken` with the NEW token before the flip, so the just-superseded
    /// previous pointer dir is in NO warm-GC retain set — past a short grace, a
    /// draft-save-triggered warm GC could reap it while a slow lock-free tunnel pass
    /// (pointer resolved, files not yet opened) sits between resolve and open, narrowing the
    /// publish GC's keep-previous "survives a single supersession" posture to a redundant
    /// cold rebuild. The long grace restores that protection without a pointer-schema change
    /// (`FilterArtifactPointer` has no previousToken field to retain instead).
    package static let warmGarbageGraceInterval: TimeInterval = 600

    /// Delete every versioned directory except the retained tokens. The caller passes
    /// the live token plus the immediately-previous one, so a reader mid-pass on the
    /// just-superseded directory still finds its files — this survives a SINGLE
    /// supersession; two rapid publishes can still evict a dir a slow reader is on
    /// (the reader then degrades to a cold rebuild, never wrong bytes). The pointer
    /// file itself is never deleted. Best-effort; failures are ignored.
    ///
    /// With a second (background) writer, both writers stage off-lock into distinct token
    /// dirs and only one holds the publish lock at flip time, so the GC's fixed retain set
    /// can never name the OTHER writer's just-staged token. A dir whose mtime is within
    /// `graceInterval` is therefore NEVER reaped: that protects a concurrently-staged dir
    /// from being deleted before its writer flips to it (which would leave a dangling
    /// pointer). Abandoned/orphaned dirs are simply reaped a cycle later, once aged out.
    package func collectVersionedGarbage(
        retaining retainedTokens: [String],
        directoryName: String = FilterArtifactStore.defaultArtifactsDirectoryName,
        graceInterval: TimeInterval = FilterArtifactStore.versionedGarbageGraceInterval
    ) {
        let rootURL = artifactsRootURL(directoryName: directoryName)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else {
            return
        }
        let retain = Set(retainedTokens)
        let now = Date()
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            guard isDirectory else { continue } // never touch the pointer file
            guard !retain.contains(entry.lastPathComponent) else { continue }
            // Never reap a freshly-staged dir a peer writer may be about to flip to.
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) < graceInterval {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
