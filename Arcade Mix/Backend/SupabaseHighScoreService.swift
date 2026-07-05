//
//  SupabaseHighScoreService.swift
//  Arcade Mix
//
//  HighScoreService backed by the Supabase `high_scores` table (PostgREST). RLS allows
//  public reads and insert-your-own-row. Compiled out until the Supabase package is added.
//

#if canImport(Supabase)
import Foundation
import Supabase

final class SupabaseHighScoreService: HighScoreService {
    private let client: SupabaseClient
    private let table = "high_scores"

    init(client: SupabaseClient) {
        self.client = client
    }

    func submit(score: Int, for gameID: GameID, difficulty: String?, user: AppUser) async throws -> HighScore {
        let payload = HighScoreInsert(
            gameID: gameID.rawValue,
            userID: user.id,
            displayName: user.leaderboardName,
            score: score,
            difficulty: difficulty
        )
        let inserted: HighScore = try await client
            .from(table)
            .insert(payload, returning: .representation)
            .single()
            .execute()
            .value
        return inserted
    }

    func topScores(for gameID: GameID, difficulty: String?, limit: Int) async throws -> [HighScore] {
        var query = client
            .from(table)
            .select()
            .eq("game_id", value: gameID.rawValue)
        if let difficulty {
            query = query.eq("difficulty", value: difficulty)
        }
        return try await query
            .order("score", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    func personalBest(for gameID: GameID, difficulty: String?, userID: String) async throws -> HighScore? {
        var query = client
            .from(table)
            .select()
            .eq("game_id", value: gameID.rawValue)
            .eq("user_id", value: userID)
        if let difficulty {
            query = query.eq("difficulty", value: difficulty)
        }
        let rows: [HighScore] = try await query
            .order("score", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }
}
#endif
