//
//  Game.swift
//  Arcade Mix
//
//  Single source of truth for the games shown in the hub. To add a game later:
//  add a `GameID` case, append a `GameInfo` (with its `category`) to `catalog`, and
//  add a branch in `RootView.gameView(for:)`.
//

import SwiftUI

/// Stable identifier for each game. `rawValue` is safe to persist (e.g. as a
/// high-score key in Supabase).
enum GameID: String, CaseIterable, Identifiable {
    case afl
    case rugby
    case connect4

    var id: String { rawValue }
}

/// Whether a game can be played yet.
enum GameStatus {
    case available
    case comingSoon
}

/// A hub section. The hub renders one titled section per category, in this order;
/// empty categories are skipped, so adding a new one is harmless until it has games.
enum GameCategory: String, CaseIterable, Identifiable {
    case sport
    case board

    var id: String { rawValue }

    var titleKey: LocalizedStringResource {
        switch self {
        case .sport: return "Hub_Category_Sport"
        case .board: return "Hub_Category_Board"
        }
    }
}

/// Display metadata for a single hub tile. All user-facing text is a
/// `LocalizedStringResource` so it resolves through the String Catalog.
struct GameInfo: Identifiable {
    let id: GameID
    let category: GameCategory
    let titleKey: LocalizedStringResource
    let subtitleKey: LocalizedStringResource
    let status: GameStatus
    let systemImage: String
    let accentColor: Color

    /// Games rendered by the hub, in display order.
    static let catalog: [GameInfo] = [
        GameInfo(
            id: .afl,
            category: .sport,
            titleKey: "Game_AFL_Title",
            subtitleKey: "Game_AFL_Subtitle",
            status: .available,
            systemImage: "figure.australian.football",
            accentColor: .red
        ),
        GameInfo(
            id: .rugby,
            category: .sport,
            titleKey: "Game_Rugby_Title",
            subtitleKey: "Game_Rugby_Subtitle",
            status: .available,
            systemImage: "figure.rugby",
            accentColor: .orange
        ),
        GameInfo(
            id: .connect4,
            category: .board,
            titleKey: "Game_Connect4_Title",
            subtitleKey: "Game_Connect4_Subtitle",
            status: .available,
            systemImage: "circle.grid.3x3.fill",
            accentColor: .blue
        )
    ]

    /// Games in a category, preserving catalog order. Used to build the hub's sections.
    static func games(in category: GameCategory) -> [GameInfo] {
        catalog.filter { $0.category == category }
    }
}
