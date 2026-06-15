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

@MainActor
final class BackendProvider: ObservableObject {
    let auth: AuthService
    let highScores: HighScoreService

    @Published private(set) var currentUser: AppUser?
    @Published private(set) var isAuthenticating = false

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
    }

    private func run(_ action: () async throws -> AppUser) async rethrows {
        isAuthenticating = true
        defer { isAuthenticating = false }
        currentUser = try await action()
    }
}
