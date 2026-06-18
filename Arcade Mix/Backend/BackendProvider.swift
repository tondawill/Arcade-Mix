//
//  BackendProvider.swift
//  Arcade Mix
//
//  Composition root for backend services + the app's auth state. Injected into the
//  SwiftUI environment by `ArcadeMixApp`. Resolves to Supabase when the package is
//  present and credentials are configured, otherwise to on-device Local services.
//

import Foundation
import Combine
import Network

@MainActor
final class BackendProvider: ObservableObject {
    let auth: AuthService
    let highScores: HighScoreService

    @Published private(set) var currentUser: AppUser?
    @Published private(set) var isAuthenticating = false

    /// True when the player chose to continue without signing in (e.g. offline). They can
    /// play, but there is no `currentUser`, so scores are not submitted.
    @Published private(set) var isGuest = false

    // MARK: - Connectivity

    private let connectivityMonitor = NWPathMonitor()
    private var isOnline = true
    /// Set when a *guest* regains connectivity; the main menu reads it to push the
    /// sign-in screen the next time it appears.
    private var pendingSignInPrompt = false

    /// True when talking to a real Supabase backend (package present + creds set).
    let usingSupabase: Bool

    init(auth: AuthService? = nil, highScores: HighScoreService? = nil) {
        if let auth, let highScores {
            self.auth = auth
            self.highScores = highScores
            self.usingSupabase = false
        } else {
            let resolved = Self.resolveServices()
            self.auth = auth ?? resolved.auth
            self.highScores = highScores ?? resolved.highScores
            self.usingSupabase = resolved.usingSupabase
        }
        self.currentUser = self.auth.currentUser
        startConnectivityMonitoring()
    }

    private func startConnectivityMonitoring() {
        connectivityMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.handleConnectivity(online: online) }
        }
        connectivityMonitor.start(queue: DispatchQueue(label: "arcademix.connectivity"))
    }

    /// On an offline→online transition while playing as a guest, queue a sign-in prompt
    /// for the next time the player is back at the main menu.
    private func handleConnectivity(online: Bool) {
        if online, !isOnline, isGuest { pendingSignInPrompt = true }
        isOnline = online
    }

    /// Called when the main menu appears: if a guest has since come online, drop guest
    /// mode so the app returns to the sign-in screen.
    func promptSignInIfPending() {
        guard pendingSignInPrompt else { return }
        pendingSignInPrompt = false
        if isGuest { isGuest = false }   // currentUser is nil → RootView shows LoginView
    }

    /// Picks Supabase services when available/configured, else Local.
    private static func resolveServices() -> (auth: AuthService, highScores: HighScoreService, usingSupabase: Bool) {
        #if canImport(Supabase)
        if let client = SupabaseClientProvider.shared {
            return (SupabaseAuthService(client: client),
                    SupabaseHighScoreService(client: client),
                    true)
        }
        #endif
        return (LocalAuthService(), LocalHighScoreService(), false)
    }

    // MARK: - Session

    /// Restore an existing session on launch.
    func bootstrap() async {
        currentUser = await auth.restoreSession()
    }

    /// Enter the app without authenticating (offline / "no account"). Scores won't save.
    func continueAsGuest() {
        isGuest = true
    }

    // MARK: - Auth actions

    func signIn(email: String, password: String) async throws {
        try await run { try await self.auth.signIn(email: email, password: password) }
    }

    func signUp(email: String, password: String) async throws {
        try await run { try await self.auth.signUp(email: email, password: password) }
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws {
        try await run {
            try await self.auth.signInWithApple(idToken: idToken, nonce: nonce, fullName: fullName)
        }
    }

    func signOut() async {
        try? await auth.signOut()
        currentUser = nil
        isGuest = false
    }

    private func run(_ action: () async throws -> AppUser) async rethrows {
        isAuthenticating = true
        defer { isAuthenticating = false }
        currentUser = try await action()
        isGuest = false
    }
}
