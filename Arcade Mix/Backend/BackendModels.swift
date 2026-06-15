//
//  BackendModels.swift
//  Arcade Mix
//
//  Plain value types exchanged with the backend. These are deliberately decoupled
//  from any SDK so the rest of the app never imports Supabase directly.
//

import Foundation

/// An authenticated user.
struct AppUser: Identifiable, Codable, Equatable {
    let id: String          // maps to Supabase auth user id (uuid)
    var email: String?
    var displayName: String?

    /// Best human-readable name for leaderboards.
    var leaderboardName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, !email.isEmpty { return email }
        return "Player"
    }
}

/// A single high-score entry for a given game. `CodingKeys` map to the snake_case
/// columns of the Supabase `high_scores` table.
struct HighScore: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    let gameID: String      // GameID.rawValue
    let userID: String
    let displayName: String
    let score: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case gameID = "game_id"
        case userID = "user_id"
        case displayName = "display_name"
        case score
        case createdAt = "created_at"
    }
}

/// Payload for inserting a new score. Omits `id` / `created_at` so the DB fills its
/// defaults. Column names match the table.
struct HighScoreInsert: Encodable {
    let gameID: String
    let userID: String
    let displayName: String
    let score: Int

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case userID = "user_id"
        case displayName = "display_name"
        case score
    }
}
