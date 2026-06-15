//
//  HighScoreService.swift
//  Arcade Mix
//
//  Global high-score abstraction. Swap `LocalHighScoreService` for the Supabase-backed
//  implementation without changing callers.
//

import Foundation

protocol HighScoreService: AnyObject {
    /// Submit a score for a game and return the stored entry.
    @discardableResult
    func submit(score: Int, for gameID: GameID, user: AppUser) async throws -> HighScore

    /// Fetch the top scores for a game, highest first.
    func topScores(for gameID: GameID, limit: Int) async throws -> [HighScore]
}

extension HighScoreService {
    /// Convenience: the single best score for a game, if any.
    func topScore(for gameID: GameID) async throws -> HighScore? {
        try await topScores(for: gameID, limit: 1).first
    }
}

/// On-device leaderboard persisted to `UserDefaults`, used until Supabase is configured.
/// Lets the hub show real, persistent high scores with no backend.
final class LocalHighScoreService: HighScoreService {
    private let defaultsKey = "arcademix.local.highScores"

    func submit(score: Int, for gameID: GameID, user: AppUser) async throws -> HighScore {
        let entry = HighScore(
            gameID: gameID.rawValue,
            userID: user.id,
            displayName: user.leaderboardName,
            score: score,
            createdAt: Date()
        )
        var all = load()
        all.append(entry)
        save(all)
        return entry
    }

    func topScores(for gameID: GameID, limit: Int) async throws -> [HighScore] {
        load()
            .filter { $0.gameID == gameID.rawValue }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Persistence

    private func load() -> [HighScore] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder.highScore.decode([HighScore].self, from: data)) ?? []
    }

    private func save(_ scores: [HighScore]) {
        if let data = try? JSONEncoder.highScore.encode(scores) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// Shared coders that handle the `Date` <-> ISO8601 representation consistently.
extension JSONEncoder {
    static var highScore: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var highScore: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
