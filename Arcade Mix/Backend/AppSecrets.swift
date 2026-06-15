//
//  AppSecrets.swift
//  Arcade Mix
//
//  Reads Supabase credentials that flow in from Config/Secrets.xcconfig →
//  Info.plist build-setting substitution. Values are optional: until you fill in
//  Secrets.xcconfig they're nil/empty, and the app keeps running on mock services.
//

import Foundation

enum AppSecrets {

    /// The Supabase project URL, rebuilt from the host stored in Secrets.xcconfig.
    /// (We store host-only because xcconfig treats "//" as a comment.)
    static var supabaseURL: URL? {
        guard let host = infoValue("SUPABASE_HOST"), !host.isEmpty,
              !host.hasPrefix("YOUR-") else { return nil }
        return URL(string: "https://\(host)")
    }

    /// The Supabase anon/public API key.
    static var supabaseAnonKey: String? {
        guard let key = infoValue("SUPABASE_ANON_KEY"), !key.isEmpty,
              !key.hasPrefix("YOUR-") else { return nil }
        return key
    }

    /// True once both credentials are present — flip your BackendProvider to the
    /// real Supabase services when this is true.
    static var isSupabaseConfigured: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }

    private static func infoValue(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
