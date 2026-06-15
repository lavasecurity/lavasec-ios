import CryptoKit
import Foundation
import LavaSecCore
import LocalAuthentication
import Security
import SwiftUI

enum SecurityBiometricKind: String {
    case unavailable
    case faceID
    case touchID
    case biometric

    var label: String {
        switch self {
        case .unavailable:
            "Biometric Unlock"
        case .faceID:
            "Face ID"
        case .touchID:
            "Touch ID"
        case .biometric:
            "Biometric Unlock"
        }
    }
}

struct SecurityPasscodeAuthenticationRequest: Identifiable {
    let id = UUID()
    let reason: String
    let surface: SecurityProtectedSurface?
}

struct SecurityPasscodeCredential: Codable, Equatable {
    let salt: Data
    let verifier: Data
}

enum SecurityPasscodeKeychainStoreError: Error, LocalizedError, Sendable {
    case randomGenerationFailed(OSStatus)
    case unexpectedItemData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "Could not prepare a passcode verifier. Security returned status \(status)."
        case .unexpectedItemData:
            "The saved passcode verifier could not be read."
        case .unhandledStatus(let status):
            "Keychain returned status \(status)."
        }
    }
}

struct SecurityPasscodeKeychainStore {
    private let account = "passcode-verifier"
    private let keychain = GenericKeychainStore(
        service: "com.lavasec.app-security",
        unexpectedItemData: SecurityPasscodeKeychainStoreError.unexpectedItemData,
        unhandledStatus: SecurityPasscodeKeychainStoreError.unhandledStatus
    )

    func save(_ credential: SecurityPasscodeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try keychain.saveData(data, account: account)
    }

    func load() throws -> SecurityPasscodeCredential? {
        guard let data = try keychain.loadData(account: account) else {
            return nil
        }

        return try JSONDecoder().decode(SecurityPasscodeCredential.self, from: data)
    }

    func delete() throws {
        try keychain.delete(account: account)
    }

    func makeCredential(for code: String) throws -> SecurityPasscodeCredential {
        let salt = try randomData(byteCount: 16)
        return SecurityPasscodeCredential(
            salt: salt,
            verifier: verifier(for: code, salt: salt)
        )
    }

    func verify(_ code: String, against credential: SecurityPasscodeCredential) -> Bool {
        verifier(for: code, salt: credential.salt) == credential.verifier
    }

    private func verifier(for code: String, salt: Data) -> Data {
        var input = Data()
        input.append(salt)
        input.append(Data(code.utf8))
        return Data(SHA256.hash(data: input))
    }

    private func randomData(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SecurityPasscodeKeychainStoreError.randomGenerationFailed(status)
        }

        return Data(bytes)
    }
}

@MainActor
final class SecurityController: ObservableObject {
    @Published private(set) var isPasscodeEnabled = false
    @Published private(set) var isBiometricEnabled = false
    @Published private(set) var biometricKind: SecurityBiometricKind = .unavailable
    @Published private(set) var canEvaluateBiometrics = false
    @Published private(set) var protectedSurfaces = Set<SecurityProtectedSurface>()
    @Published var passcodeAuthenticationRequest: SecurityPasscodeAuthenticationRequest?
    @Published private(set) var isAppUnlockBlockingUI = false
    @Published private(set) var isAppUnlockPrivacyMaskVisible = false
    @Published private(set) var statusMessage: String?

    private let defaults: UserDefaults
    private let keychainStore: SecurityPasscodeKeychainStore
    private var isAppUnlockSessionAuthenticated = false
    private var authenticatedSurfacesForCurrentTurn = Set<SecurityProtectedSurface>()
    private var isCredentialAuthenticatedForCurrentTurn = false
    private var passcodeContinuations = [UUID: [CheckedContinuation<Bool, Never>]]()
    private var isAuthenticatingAppUnlock = false
    private var isBiometricAuthenticationInProgress = false

    private let biometricEnabledDefaultsKey = "securityBiometricEnabled"
    init(
        defaults: UserDefaults = LavaSecAppGroup.sharedDefaults,
        keychainStore: SecurityPasscodeKeychainStore = SecurityPasscodeKeychainStore()
    ) {
        self.defaults = defaults
        self.keychainStore = keychainStore

        #if DEBUG
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_RESET_SECURITY"] == "1" {
            try? keychainStore.delete()
            defaults.removeObject(forKey: biometricEnabledDefaultsKey)
            defaults.removeObject(forKey: SecurityProtectedSurfaceStorage.defaultsKey)
        }
        #endif

        isPasscodeEnabled = (try? keychainStore.load()) != nil
        isBiometricEnabled = defaults.bool(forKey: biometricEnabledDefaultsKey) && isPasscodeEnabled
        protectedSurfaces = SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults)
        refreshBiometricKind()

        if !isPasscodeEnabled {
            clearSecurityPreferencesAfterPasscodeRemoval()
        }
    }

    var biometricToggleTitle: String {
        biometricKind.label
    }

    var shouldShowBiometricToggle: Bool {
        biometricKind != .unavailable
    }

    var canEnableBiometrics: Bool {
        isPasscodeEnabled && canEvaluateBiometrics && faceIDUsageDescriptionIsPresent
    }

    var hasAuthenticationMethod: Bool {
        isPasscodeEnabled || isBiometricEnabled
    }

    private var faceIDUsageDescriptionIsPresent: Bool {
        guard biometricKind == .faceID else {
            return true
        }

        guard let value = Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String else {
            return false
        }

        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var securityStatusSummary: String {
        if isPasscodeEnabled {
            return isBiometricEnabled ? "Passcode and \(biometricToggleTitle)" : "Passcode on"
        }

        return "Passcode off"
    }

    func isProtected(_ surface: SecurityProtectedSurface) -> Bool {
        protectedSurfaces.contains(surface)
    }

    func setProtection(_ isProtected: Bool, for surface: SecurityProtectedSurface) {
        guard hasAuthenticationMethod else {
            if protectedSurfaces.remove(surface) != nil {
                saveProtectedSurfaces()
            }
            if surface == .appUnlock {
                isAppUnlockSessionAuthenticated = false
                isAppUnlockBlockingUI = false
                isAppUnlockPrivacyMaskVisible = false
            }
            resetViewAuthenticationTurn()
            return
        }

        if isProtected {
            protectedSurfaces.insert(surface)
        } else {
            protectedSurfaces.remove(surface)
        }

        saveProtectedSurfaces()
        if surface == .appUnlock {
            isAppUnlockSessionAuthenticated = isProtected
            isAppUnlockBlockingUI = false
            if !isProtected {
                isAppUnlockPrivacyMaskVisible = false
            }
        }
        resetViewAuthenticationTurn()
    }

    func setPasscode(_ code: String) throws {
        let credential = try keychainStore.makeCredential(for: code)
        try keychainStore.save(credential)
        isPasscodeEnabled = true
        statusMessage = nil
    }

    func disablePasscode() {
        try? keychainStore.delete()
        isPasscodeEnabled = false
        isAppUnlockSessionAuthenticated = false
        resetViewAuthenticationTurn()
        isAppUnlockBlockingUI = false
        isAppUnlockPrivacyMaskVisible = false
        clearSecurityPreferencesAfterPasscodeRemoval()
    }

    func setBiometricEnabled(_ isEnabled: Bool) async {
        guard isPasscodeEnabled else {
            isBiometricEnabled = false
            defaults.set(false, forKey: biometricEnabledDefaultsKey)
            return
        }

        if isEnabled {
            refreshBiometricKind()
            guard faceIDUsageDescriptionIsPresent else {
                isBiometricEnabled = false
                defaults.set(false, forKey: biometricEnabledDefaultsKey)
                statusMessage = "\(biometricToggleTitle) is not available in this build"
                return
            }

            guard await evaluateBiometrics(reason: "Enable \(biometricToggleTitle) for Lava") else {
                statusMessage = "\(biometricToggleTitle) was not enabled."
                return
            }
        }

        isBiometricEnabled = isEnabled
        defaults.set(isEnabled, forKey: biometricEnabledDefaultsKey)
        statusMessage = nil
    }

    func requireAuthentication(for surface: SecurityProtectedSurface, reason: String) async -> Bool {
        guard isPasscodeEnabled, protectedSurfaces.contains(surface) else {
            return true
        }

        if authenticatedSurfacesForCurrentTurn.contains(surface) {
            return true
        }

        return await authenticate(surface: surface, reason: reason)
    }

    func requireFreshAuthentication(for surface: SecurityProtectedSurface, reason: String) async -> Bool {
        guard isPasscodeEnabled, protectedSurfaces.contains(surface) else {
            return true
        }

        return await authenticate(surface: surface, reason: reason)
    }

    func requireCredentialAuthentication(reason: String) async -> Bool {
        guard isPasscodeEnabled else {
            return true
        }

        if isCredentialAuthenticatedForCurrentTurn {
            return true
        }

        return await authenticate(surface: nil, reason: reason)
    }

    func requirePasscodeAuthentication(reason: String) async -> Bool {
        guard isPasscodeEnabled else {
            return true
        }

        return await requestPasscode(surface: nil, reason: reason)
    }

    func requireBiometricAuthentication(reason: String) async -> Bool {
        guard isPasscodeEnabled, isBiometricEnabled else {
            return true
        }

        refreshBiometricKind()
        guard canEnableBiometrics else {
            statusMessage = "\(biometricToggleTitle) is not available."
            return false
        }

        let didAuthenticate = await evaluateBiometrics(reason: reason)
        if !didAuthenticate {
            statusMessage = "\(biometricToggleTitle) authentication failed"
        } else {
            statusMessage = nil
        }

        return didAuthenticate
    }

    func verifyPasscode(_ code: String) -> Bool {
        guard let credential = try? keychainStore.load() else {
            return false
        }

        return keychainStore.verify(code, against: credential)
    }

    func completePasscodeAuthentication(requestID: UUID, code: String) -> Bool {
        guard verifyPasscode(code) else {
            return false
        }

        markAuthenticated(surface: passcodeAuthenticationRequest?.surface)
        statusMessage = nil
        passcodeAuthenticationRequest = nil
        let continuations = passcodeContinuations.removeValue(forKey: requestID) ?? []
        for continuation in continuations {
            continuation.resume(returning: true)
        }
        return true
    }

    func cancelPasscodeAuthentication(requestID: UUID) {
        passcodeAuthenticationRequest = nil
        let continuations = passcodeContinuations.removeValue(forKey: requestID) ?? []
        for continuation in continuations {
            continuation.resume(returning: false)
        }
    }

    func resetForegroundSession() {
        isAppUnlockSessionAuthenticated = false
        resetViewAuthenticationTurn()
    }

    func resetViewAuthenticationTurn() {
        authenticatedSurfacesForCurrentTurn = []
        isCredentialAuthenticatedForCurrentTurn = false
    }

    func lockForBackgroundIfNeeded() {
        resetForegroundSession()
        if isPasscodeEnabled, protectedSurfaces.contains(.appUnlock) {
            isAppUnlockBlockingUI = true
            isAppUnlockPrivacyMaskVisible = true
        }
    }

    func showAppUnlockPrivacyMaskIfNeeded() {
        guard !isBiometricAuthenticationInProgress else {
            return
        }

        guard isPasscodeEnabled, protectedSurfaces.contains(.appUnlock) else {
            isAppUnlockPrivacyMaskVisible = false
            return
        }

        isAppUnlockPrivacyMaskVisible = true
    }

    func hideAppUnlockPrivacyMask() {
        isAppUnlockPrivacyMaskVisible = false
    }

    func authenticateAppUnlockIfNeeded() async {
        guard isPasscodeEnabled, protectedSurfaces.contains(.appUnlock) else {
            isAppUnlockBlockingUI = false
            isAppUnlockPrivacyMaskVisible = false
            return
        }

        guard !isAppUnlockSessionAuthenticated else {
            isAppUnlockBlockingUI = false
            isAppUnlockPrivacyMaskVisible = false
            return
        }

        guard !isAuthenticatingAppUnlock else {
            return
        }

        isAuthenticatingAppUnlock = true
        defer {
            isAuthenticatingAppUnlock = false
        }

        isAppUnlockBlockingUI = true
        if await authenticate(surface: .appUnlock, reason: "Unlock Lava") {
            isAppUnlockBlockingUI = false
            isAppUnlockPrivacyMaskVisible = false
        }
    }

    func refreshBiometricKind() {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        canEvaluateBiometrics = canEvaluate

        switch context.biometryType {
        case .faceID:
            biometricKind = .faceID
        case .touchID:
            biometricKind = .touchID
        default:
            biometricKind = .unavailable
        }

        guard canEvaluate else {
            isBiometricEnabled = false
            defaults.set(false, forKey: biometricEnabledDefaultsKey)
            return
        }
    }

    private func authenticate(surface: SecurityProtectedSurface?, reason: String) async -> Bool {
        refreshBiometricKind()
        guard faceIDUsageDescriptionIsPresent else {
            isBiometricEnabled = false
            defaults.set(false, forKey: biometricEnabledDefaultsKey)
            return await requestPasscode(surface: surface, reason: reason)
        }

        if isBiometricEnabled, await evaluateBiometrics(reason: reason) {
            markAuthenticated(surface: surface)
            statusMessage = nil
            return true
        }

        return await requestPasscode(surface: surface, reason: reason)
    }

    private func evaluateBiometrics(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        isBiometricAuthenticationInProgress = true
        defer {
            isBiometricAuthenticationInProgress = false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func requestPasscode(surface: SecurityProtectedSurface?, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            if let activeRequest = passcodeAuthenticationRequest {
                passcodeContinuations[activeRequest.id, default: []].append(continuation)
                return
            }

            let request = SecurityPasscodeAuthenticationRequest(reason: reason, surface: surface)
            passcodeContinuations[request.id] = [continuation]
            passcodeAuthenticationRequest = request
        }
    }

    private func markAuthenticated(surface: SecurityProtectedSurface?) {
        if let surface {
            if surface == .appUnlock {
                isAppUnlockSessionAuthenticated = true
                return
            }

            authenticatedSurfacesForCurrentTurn.insert(surface)
        } else {
            isCredentialAuthenticatedForCurrentTurn = true
        }
    }

    private func saveProtectedSurfaces() {
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces(protectedSurfaces, to: defaults)
    }

    private func clearSecurityPreferencesAfterPasscodeRemoval() {
        isBiometricEnabled = false
        protectedSurfaces = []
        defaults.set(false, forKey: biometricEnabledDefaultsKey)
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([], to: defaults)
    }
}

struct SecurityLockOverlay: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Lava Locked")
                    .font(.title.bold())

                Button("Unlock Lava", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(LavaStyle.safeControlGreen)
            }
        }
        .accessibilityIdentifier("securityLockOverlay")
    }
}

struct SecurityPrivacyMaskOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Lava Security")
                    .font(.title2.bold())
            }
        }
        .accessibilityIdentifier("securityPrivacyMaskOverlay")
    }
}

struct SecurityPasscodeAuthenticationView: View {
    @EnvironmentObject private var security: SecurityController
    let request: SecurityPasscodeAuthenticationRequest
    @State private var code = ""
    @State private var message: String?
    @State private var isPasscodeFieldFocused = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                VStack(spacing: 8) {
                    Text("Enter Passcode")
                        .font(.title.bold())
                    Text(request.reason.lavaLocalized)
                        .lavaSupportingText()
                        .multilineTextAlignment(.center)
                }

                SecurityPasscodeDigitsView(code: code)

                if let message {
                    Text(message.lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }

                SecurityHiddenPasscodeField(code: $code, isFocused: $isPasscodeFieldFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: code) { _, newValue in
                        handleCodeChange(newValue)
                    }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LavaStyle.groupedBackground.ignoresSafeArea())
            .navigationTitle("Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        security.cancelPasscodeAuthentication(requestID: request.id)
                    }
                }
            }
            .task {
                await focusPasscodeField()
            }
            .onTapGesture {
                isPasscodeFieldFocused = true
            }
        }
        .interactiveDismissDisabled()
    }

    @MainActor
    private func focusPasscodeField() async {
        isPasscodeFieldFocused = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        isPasscodeFieldFocused = true
    }

    private func handleCodeChange(_ value: String) {
        let filtered = String(value.filter(\.isNumber).prefix(4))
        if filtered != value {
            code = filtered
            return
        }

        guard filtered.count == 4 else {
            return
        }

        if security.completePasscodeAuthentication(requestID: request.id, code: filtered) {
            code = ""
        } else {
            message = "Wrong passcode"
            code = ""
        }
    }
}

struct SecurityPasscodeDigitsView: View {
    let code: String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < code.count ? LavaStyle.safeGreen : LavaStyle.secondaryText.opacity(0.22))
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

struct SecurityHiddenPasscodeField: UIViewRepresentable {
    @Binding var code: String
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> SecurityPasscodeTextField {
        let uiView = SecurityPasscodeTextField(frame: .zero)
        uiView.keyboardType = .numberPad
        uiView.textContentType = .oneTimeCode
        uiView.tintColor = .clear
        uiView.textColor = .clear
        uiView.backgroundColor = .clear
        uiView.autocorrectionType = .no
        uiView.delegate = context.coordinator
        uiView.accessibilityLabel = "Passcode"
        return uiView
    }

    func updateUIView(_ uiView: SecurityPasscodeTextField, context: Context) {
        if uiView.text != code {
            uiView.text = code
        }

        uiView.wantsFocus = isFocused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(code: $code)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private var code: Binding<String>

        init(code: Binding<String>) {
            self.code = code
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let currentText = textField.text ?? ""
            guard let textRange = Range(range, in: currentText) else {
                return false
            }

            let replacement = currentText.replacingCharacters(in: textRange, with: string)
            let nextCode = String(replacement.filter(\.isNumber).prefix(4))
            code.wrappedValue = nextCode
            textField.text = nextCode
            return false
        }
    }
}

final class SecurityPasscodeTextField: UITextField {
    var wantsFocus = false {
        didSet {
            updateFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFirstResponder()
    }

    private func updateFirstResponder() {
        if wantsFocus {
            focusWhenAttached()
        } else if isFirstResponder {
            resignFirstResponder()
        }
    }

    private func focusWhenAttached() {
        guard !isFirstResponder else {
            return
        }

        for delay in [0.08, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wantsFocus, self.window != nil, !self.isFirstResponder else {
                    return
                }

                self.becomeFirstResponder()
            }
        }
    }
}
