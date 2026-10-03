#!/usr/bin/env python3
"""Execute actual account sign-in/refresh/deletion methods with suspended network doubles.

--baseline-refresh --baseline-ref REF replaces only refresh methods for a deliberate RED run.
No credentials or network calls are used; the integrated app build verifies platform wiring.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'LavaSecApp/AccountAuthService.swift').read_text()
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-refresh', action='store_true')
parser.add_argument('--baseline-ref')
args = parser.parse_args()
if args.baseline_refresh != bool(args.baseline_ref):
    parser.error('--baseline-refresh requires an explicit --baseline-ref, and vice versa')
baseline = subprocess.check_output(['git', 'show', f'{args.baseline_ref}:LavaSecApp/AccountAuthService.swift'], cwd=root, text=True) if args.baseline_refresh else source

def method(name, text=source):
    start = text.index('    ' + name)
    cursor = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[cursor] == '{': depth += 1
        elif text[cursor] == '}': depth -= 1
        cursor += 1
    return text[start:cursor]

methods = '\n'.join(method(name, baseline if name in ['func currentBackupSessions()', 'func refreshCurrentSessions()', 'private func refreshSavedSession('] else source) for name in [
    'func signInWithApple()', 'func signInWithGoogle()', 'func currentBackupSession()',
    'func currentBackupSessions()', 'func refreshCurrentSession()', 'func refreshCurrentSessions()',
    'func deleteAccount(preparing:', 'func signOut()', 'private func refreshSavedSession(',
    'private func replaceSavedSessionsIfNeeded(',
    'private static func makeConnections(\n        from sessions:',
    'private static func makeConnections(\n        from session:',
    'private static func makeConnection(', 'private static func canonicalSessions(',
    'private static func uniqueBackupSessions(',
])
models = source[source.index('enum AccountAuthProvider:'):source.index('enum AccountAuthError:')]
models += source[source.index('private extension SupabaseIDTokenAuthSession {'):]
records = (root / 'Sources/LavaSecAppServices/SupabaseIDTokenAuth.swift').read_text()
records = records[:records.index('package enum SupabaseIDTokenAuthError')].replace('import LavaSecKit', '')
stubs = r'''
struct BackupAccountSession: Equatable, Sendable { let userID: String; let accessToken: String }
enum AccountAuthError: Error { case cancelled, notConfigured, authorizationAlreadyInProgress, missingIdentityToken, invalidIdentityToken, googleSignInAlreadyInProgress }
enum NetworkError: Error { case failed }
struct AppleCredential { let identityToken: Data?; let email: String? }
struct GoogleCredential { let idToken: String; let accessToken: String; let email: String? }
@MainActor final class GIDSignIn { static let sharedInstance = GIDSignIn(); func signOut() {} }
@MainActor final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class SessionStore {
    var sessions: [AccountAuthProvider: SupabaseIDTokenAuthSession] = [:]
    func loadSessions() throws -> [AccountAuthProvider: SupabaseIDTokenAuthSession] { sessions }
    func saveSession(_ session: SupabaseIDTokenAuthSession, provider: AccountAuthProvider) throws { sessions[provider] = session }
    func deleteSession(provider: AccountAuthProvider) throws { sessions[provider] = nil }
    func deleteAllSessions() throws { sessions = [:] }
}
@MainActor final class Client {
    var refresh: ((String) async throws -> SupabaseIDTokenAuthSession)?
    var signIn: (() async throws -> SupabaseIDTokenAuthSession)?
    func refreshSession(refreshToken: String) async throws -> SupabaseIDTokenAuthSession { try await refresh!(refreshToken) }
    func signInWithApple(identityToken: String, nonce: String) async throws -> SupabaseIDTokenAuthSession { try await signIn!() }
    func signInWithGoogle(identityToken: String, accessToken: String, nonce: String) async throws -> SupabaseIDTokenAuthSession { try await signIn!() }
}
@MainActor final class RPC {
    var calls: [String] = []
    var hook: (() async throws -> Void)?
}
@MainActor struct AccountDeletionClient {
    let urlSession: RPC
    func deleteAccount(accessToken: String) async throws { urlSession.calls.append(accessToken); try await urlSession.hook?() }
}
@MainActor final class Subject {
    var state = AccountAuthState.signedOut
    let authClient: Client? = Client()
    let sessionStore = SessionStore()
    let urlSession = RPC()
    var authorizationContinuation: Bool?
    var isGoogleSignInInProgress = false
    var sessionGeneration: UInt64 = 0
    static func makeRandomNonce() throws -> String { "fixture" }
    static func sha256(_ string: String) -> String { string }
    func requestAppleCredential(hashedNonce: String) async throws -> AppleCredential { AppleCredential(identityToken: Data("fixture".utf8), email: nil) }
    func requestGoogleCredential(rawNonce: String) async throws -> GoogleCredential { GoogleCredential(idToken: "fixture", accessToken: "fixture", email: nil) }
    func seed(_ session: SupabaseIDTokenAuthSession) {
        sessionStore.sessions = [.google: session]
        state = .signedIn(connections: Self.makeConnections(from: sessionStore.sessions))
    }
}
'''
# Inject all production methods inside the otherwise controlled service shell.
stubs = stubs[:-2] + methods + '\n}\n'
tests = r'''
@main struct Tests {
    static func session(_ id: String, _ token: String, expired: Bool = false) -> SupabaseIDTokenAuthSession {
        SupabaseIDTokenAuthSession(accessToken: token, refreshToken: token, expiresIn: nil,
            expiresAt: expired ? 1 : nil, user: SupabaseIDTokenAuthUser(id: id, email: nil, provider: "google"))
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        fatalError("suspension point not reached")
    }
    @MainActor static func check(_ subject: Subject, id: String?, token: String?) {
        precondition(subject.state.session?.userID == id, "stale async operation changed published account")
        precondition(subject.sessionStore.sessions[.google]?.accessToken == token, "stale async operation changed stored session")
    }
    @MainActor static func main() async throws {
        // Different-account and same-account re-sign-in: old success/error owns neither new tokens nor state.
        for id in ["B", "A"] {
            for fails in [false, true] {
                let subject = Subject(), gate = Gate()
                subject.seed(session("A", "old"))
                subject.authClient!.refresh = { _ in await gate.wait(); if fails { throw NetworkError.failed }; return session("A", "refreshed-old") }
                let refresh = Task { try? await subject.refreshCurrentSession() }
                await until { gate.continuation != nil }
                subject.authClient!.signIn = { session(id, "new") }
                _ = try await subject.signInWithGoogle()
                gate.release(); _ = await refresh.value
                check(subject, id: id, token: "new")
            }
        }
        do {
            let subject = Subject(), refreshGate = Gate(), deletionGate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.refresh = { _ in await refreshGate.wait(); return session("A", "refreshed-old") }
            let refresh = Task { try? await subject.refreshCurrentSession() }
            await until { refreshGate.continuation != nil }
            subject.urlSession.hook = { await deletionGate.wait() }
            let deletion = Task { try await subject.deleteAccount(preparing: { _ in }) }
            await until { deletionGate.continuation != nil }
            subject.authClient!.signIn = { session("B", "new") }
            _ = try await subject.signInWithGoogle()
            refreshGate.release(); _ = await refresh.value
            deletionGate.release()
            let deleted = try await deletion.value
            precondition(deleted == "A" && subject.urlSession.calls == ["old"])
            check(subject, id: "B", token: "new")
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.refresh = { _ in await gate.wait(); return session("A", "late") }
            let refresh = Task { try? await subject.refreshCurrentSession() }
            await until { gate.continuation != nil }
            subject.signOut()
            gate.release(); _ = await refresh.value
            check(subject, id: nil, token: nil)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.signIn = { await gate.wait(); return session("B", "late") }
            let signIn = Task { try? await subject.signInWithGoogle() }
            await until { gate.continuation != nil }
            subject.signOut()
            gate.release(); _ = await signIn.value
            check(subject, id: nil, token: nil)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.signIn = { await gate.wait(); throw NetworkError.failed }
            let oldSignIn = Task { try? await subject.signInWithApple() }
            await until { gate.continuation != nil }
            subject.authClient!.signIn = { session("B", "new") }
            _ = try await subject.signInWithGoogle()
            gate.release(); _ = await oldSignIn.value
            check(subject, id: "B", token: "new")
        }
        do {
            let subject = Subject(), signInGate = Gate(), refreshGate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.signIn = { await signInGate.wait(); return session("B", "new") }
            let signIn = Task { try await subject.signInWithGoogle() }
            await until { signInGate.continuation != nil }
            subject.authClient!.refresh = { _ in await refreshGate.wait(); return session("A", "late") }
            let refresh = Task { try? await subject.refreshCurrentSession() }
            await until { refreshGate.continuation != nil }
            signInGate.release(); _ = try await signIn.value
            refreshGate.release(); _ = await refresh.value
            check(subject, id: "B", token: "new")
        }
        for deletion in [false, true] {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old", expired: true))
            subject.authClient!.refresh = { _ in await gate.wait(); return session("A", "late") }
            let operation = Task {
                if deletion { _ = try? await subject.deleteAccount(preparing: { _ in fatalError("stale deletion preflight") }) }
                else { _ = try? await subject.currentBackupSession() }
            }
            await until { gate.continuation != nil }
            subject.authClient!.signIn = { session("B", "new") }
            _ = try await subject.signInWithGoogle()
            gate.release(); await operation.value
            check(subject, id: "B", token: "new")
            precondition(subject.urlSession.calls.isEmpty)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old"))
            subject.authClient!.refresh = { _ in await gate.wait(); throw NetworkError.failed }
            let lateFailure = Task { try? await subject.refreshCurrentSession() }
            await until { gate.continuation != nil }
            subject.authClient!.refresh = { _ in session("A", "rotated") }
            _ = try await subject.refreshCurrentSession()
            gate.release(); _ = await lateFailure.value
            check(subject, id: "A", token: "rotated")
        }
        for completeBeforeDeletion in [false, true] {
            let subject = Subject(), deletionGate = Gate(), signInGate = Gate()
            subject.seed(session("A", "old"))
            subject.urlSession.hook = { await deletionGate.wait() }
            let deletion = Task { try await subject.deleteAccount(preparing: { _ in }) }
            await until { deletionGate.continuation != nil }
            subject.authClient!.signIn = { await signInGate.wait(); throw AccountAuthError.cancelled }
            let signIn = Task { try? await subject.signInWithGoogle() }
            await until { signInGate.continuation != nil }
            if completeBeforeDeletion {
                signInGate.release(); _ = await signIn.value
                deletionGate.release(); _ = try await deletion.value
            } else {
                deletionGate.release(); _ = try await deletion.value
                signInGate.release(); _ = await signIn.value
            }
            check(subject, id: nil, token: nil)
        }
        do {
            let subject = Subject(), gate = Gate()
            subject.seed(session("A", "old"))
            subject.urlSession.hook = { await gate.wait() }
            let deletion = Task { try await subject.deleteAccount(preparing: { _ in }) }
            await until { gate.continuation != nil }
            subject.authClient!.signIn = { session("A", "new") }
            _ = try await subject.signInWithGoogle()
            gate.release(); _ = try await deletion.value
            check(subject, id: nil, token: nil)
        }
        do {
            let subject = Subject(), deletionGate = Gate(), signInGate = Gate()
            subject.seed(session("A", "old"))
            subject.urlSession.hook = { await deletionGate.wait() }
            let deletion = Task { try await subject.deleteAccount(preparing: { _ in }) }
            await until { deletionGate.continuation != nil }
            subject.authClient!.signIn = { await signInGate.wait(); return session("A", "late-new") }
            let signIn = Task { try? await subject.signInWithGoogle() }
            await until { signInGate.continuation != nil }
            deletionGate.release(); _ = try await deletion.value
            signInGate.release(); _ = await signIn.value
            check(subject, id: nil, token: nil)
        }
        print("PASS: 16 production-method account ownership scenarios")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-account-ownership-') as directory:
    p = Path(directory)
    swift = p / 'Ownership.swift'
    swift.write_text(records + models + stubs + tests)
    env = os.environ.copy()
    env['CLANG_MODULE_CACHE_PATH'] = '/tmp/lava-backup-lifecycle-clang'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', str(swift), '-o', str(p / 'tests')], check=True, env=env)
    subprocess.run([str(p / 'tests')], check=True, env=env)
