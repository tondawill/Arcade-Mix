//
//  SupabaseAuthService.swift
//  Arcade Mix
//
//  AuthService backed by Supabase Auth (GoTrue). Supports native Sign in with Apple
//  (id-token exchange) and email/password. Compiled out until the Supabase package is
//  added.
//

#if canImport(Supabase)
import Foundation
import Supabase

final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient
    private(set) var currentUser: AppUser?

    init(client: SupabaseClient) {
        self.client = client
    }

    func restoreSession() async -> AppUser? {
        if let session = try? await client.auth.session {
            currentUser = Self.appUser(from: session.user)
        } else {
            currentUser = nil
        }
        return currentUser
    }

    func signIn(email: String, password: String) async throws -> AppUser {
        let session = try await client.auth.signIn(email: email, password: password)
        return store(session.user)
    }

    func signUp(email: String, password: String) async throws -> AppUser {
        let response = try await client.auth.signUp(email: email, password: password)
        return store(response.user)
    }

    func signInWithApple(idToken: String, nonce: String, fullName: String?) async throws -> AppUser {
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        var user = Self.appUser(from: session.user)
        if (user.displayName ?? "").isEmpty, let fullName, !fullName.isEmpty {
            user.displayName = fullName
        }
        currentUser = user
        return user
    }

    func signOut() async throws {
        try await client.auth.signOut()
        currentUser = nil
    }

    // MARK: - Mapping

    @discardableResult
    private func store(_ user: Auth.User) -> AppUser {
        let mapped = Self.appUser(from: user)
        currentUser = mapped
        return mapped
    }

    private static func appUser(from user: Auth.User) -> AppUser {
        let name = (user.userMetadata["full_name"]?.stringValue)
            ?? (user.userMetadata["name"]?.stringValue)
        return AppUser(id: user.id.uuidString, email: user.email, displayName: name)
    }
}
#endif
