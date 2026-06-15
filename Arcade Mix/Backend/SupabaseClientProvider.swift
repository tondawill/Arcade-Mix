//
//  SupabaseClientProvider.swift
//  Arcade Mix
//
//  Builds the shared SupabaseClient from `AppSecrets`. Entirely compiled out until the
//  Supabase Swift package is added to the project (see SUPABASE_SETUP.md).
//

#if canImport(Supabase)
import Foundation
import Supabase

enum SupabaseClientProvider {
    /// The shared client, or nil if credentials aren't configured yet.
    static let shared: SupabaseClient? = {
        guard let url = AppSecrets.supabaseURL, let key = AppSecrets.supabaseAnonKey else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()
}
#endif
