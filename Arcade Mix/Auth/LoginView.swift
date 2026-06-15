//
//  LoginView.swift
//  Arcade Mix
//
//  Sign-in gate shown until the player is authenticated. Offers Sign in with Apple
//  (primary) and an email/password fallback. All copy is localized.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject private var backend: BackendProvider

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var errorMessage: String?
    @State private var appleRequest = SignInWithApple.makeRequest()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Login_Title")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    SignInWithAppleButton(.signIn) { request in
                        appleRequest = SignInWithApple.makeRequest()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = appleRequest.hashedNonce
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)

                    HStack {
                        Rectangle().frame(height: 1).opacity(0.2)
                        Text(verbatim: "—").opacity(0.4)
                        Rectangle().frame(height: 1).opacity(0.2)
                    }

                    emailForm

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private var emailForm: some View {
        VStack(spacing: 12) {
            TextField("Login_Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            SecureField("Login_Password", text: $password)
                .textContentType(isSignUp ? .newPassword : .password)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await submitEmail() }
            } label: {
                Group {
                    if backend.isAuthenticating {
                        ProgressView()
                    } else {
                        Text(isSignUp ? "Login_SignUp" : "Login_SignIn").bold()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || password.isEmpty || backend.isAuthenticating)

            Button {
                isSignUp.toggle()
                errorMessage = nil
            } label: {
                Text(isSignUp ? "Login_Toggle_ToSignIn" : "Login_Toggle_ToSignUp")
                    .font(.footnote)
            }
        }
    }

    // MARK: - Actions

    private func submitEmail() async {
        errorMessage = nil
        do {
            if isSignUp {
                try await backend.signUp(email: email, password: password)
            } else {
                try await backend.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = String(localized: "Login_Error")
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = SignInWithApple.credential(from: authorization) else {
                errorMessage = String(localized: "Login_Error")
                return
            }
            Task {
                errorMessage = nil
                do {
                    try await backend.signInWithApple(
                        idToken: credential.idToken,
                        nonce: appleRequest.rawNonce,
                        fullName: credential.fullName
                    )
                } catch {
                    errorMessage = String(localized: "Login_Error")
                }
            }
        case .failure:
            // User cancellation or no entitlement — keep the screen, no scary error.
            break
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(BackendProvider())
}
