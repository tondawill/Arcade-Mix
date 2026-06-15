//
//  SignInWithApple.swift
//  Arcade Mix
//
//  Helpers for native Sign in with Apple: a secure nonce and a parser that turns an
//  `ASAuthorization` into the (idToken, rawNonce, fullName) needed by the auth layer.
//

import Foundation
import AuthenticationServices
import CryptoKit

enum SignInWithApple {

    /// A fresh login attempt: keep the raw nonce, send its SHA256 to Apple.
    struct Request {
        let rawNonce: String
        var hashedNonce: String { sha256(rawNonce) }
    }

    static func makeRequest() -> Request {
        Request(rawNonce: randomNonce())
    }

    /// Result of a successful authorization, ready for `AuthService.signInWithApple`.
    struct Credential {
        let idToken: String
        let fullName: String?
    }

    /// Extracts the identity token + display name from a completed authorization.
    static func credential(from authorization: ASAuthorization) -> Credential? {
        guard
            let appleID = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = appleID.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else { return nil }

        let name = [appleID.fullName?.givenName, appleID.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        return Credential(idToken: idToken, fullName: name.isEmpty ? nil : name)
    }

    // MARK: - Nonce

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status == errSecSuccess, random < charset.count * (256 / charset.count) {
                result.append(charset[Int(random) % charset.count])
                remaining -= 1
            }
        }
        return result
    }
}
