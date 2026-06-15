//
//  AuthService.swift
//  Arcade Mix
//
//  Authentication abstraction. The app depends only on this protocol; the Supabase
//  implementation drops in behind it (see SupabaseAuthService) without touching call
//  sites.
//

import Foundation

protocol AuthService: AnyObject {
    var currentUser: AppUser? { get }

    /// Restore any persisted / existing session. Returns the user if signed in.
    @discardableResult
    func restoreSession() async -> AppUser?

    @discardableResult
    func signIn(email: String, password: String) async throws -> AppUser

    @discardableResult
    func signUp(email: String, password: String) async throws -> AppUser

    /// Sign in using a native Sign in with Apple identity token.
    @discardableResult
    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> AppUser

    func signOut() async throws
}

/// On-device auth used until Supabase is configured. Persists the signed-in user to
/// `UserDefaults` so login survives launches and the rest of the app works offline.
/// "Sign in" here is local only — there is no password verification.
final class LocalAuthService: AuthService {
    private let defaultsKey = "arcademix.local.currentUser"
    private(set) var currentUser: AppUser?

    init() {
        currentUser = loadPersisted()
    }

    func restoreSession() async -> AppUser? {
        currentUser = loadPersisted()
        return currentUser
    }

    func signIn(email: String, password: String) async throws -> AppUser {
        let user = AppUser(id: stableID(for: email), email: email, displayName: email)
        persist(user)
        return user
    }

    func signUp(email: String, password: String) async throws -> AppUser {
        try await signIn(email: email, password: password)
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> AppUser {
        // Without Supabase we can't verify the token, but we can still derive a stable
        // local identity from it so the player has a name.
        let user = AppUser(id: stableID(for: idToken),
                           email: nil,
                           displayName: fullName?.isEmpty == false ? fullName : "Apple Player")
        persist(user)
        return user
    }

    func signOut() async throws {
        currentUser = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - Persistence

    private func persist(_ user: AppUser) {
        currentUser = user
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadPersisted() -> AppUser? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(AppUser.self, from: data)
    }

    private func stableID(for seed: String) -> String {
        // Deterministic id so the same email/token maps to the same local user.
        "local-\(abs(seed.hashValue))"
    }
}
