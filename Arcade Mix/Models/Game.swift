//
//  Game.swift
//  Arcade Mix
//
//  Single source of truth for the games shown in the hub. To add a game later:
//  add a `GameID` case, append a `GameInfo` (with its `category` and `howToPlay`) to
//  `catalog`, and add a branch in `RootView.gameView(for:)`.
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

/// A simple SwiftUI-drawn illustration for a rule (rendered by `RuleDiagramView`).
enum RuleDiagram {
    case pitch(tryLine: Bool)     // top-down field + scoring line + a runner crossing it
    case goalPosts(rugby: Bool)   // posts (rugby adds a crossbar) with the ball scoring
    case connectFour              // 7×6 grid with a winning line of four lit
}

/// Per-game help shown in the "How to Play" sheet (opened from the "?" in each game's menu).
/// Every game must supply this, so new games always ship with player-facing help.
struct HowToPlay {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String                        // SF Symbol (shown when there's no diagram)
        let textKey: LocalizedStringResource
        var diagram: RuleDiagram? = nil         // optional drawn illustration for a key rule
    }
    let controls: [Item]
    let rules: [Item]
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
    let howToPlay: HowToPlay

    /// Games rendered by the hub, in display order.
    static let catalog: [GameInfo] = [
        GameInfo(
            id: .afl,
            category: .sport,
            titleKey: "Game_AFL_Title",
            subtitleKey: "Game_AFL_Subtitle",
            status: .available,
            systemImage: "figure.australian.football",
            accentColor: .red,
            howToPlay: HowToPlay(
                controls: [
                    .init(icon: "arrow.up.and.down.and.arrow.left.and.right", textKey: "AFL_HowTo_Control_Move"),
                    .init(icon: "hand.point.up.left.fill", textKey: "AFL_HowTo_Control_Pass"),
                    .init(icon: "arrow.up", textKey: "AFL_HowTo_Control_Kick")
                ],
                rules: [
                    .init(icon: "figure.australian.football", textKey: "AFL_HowTo_Rule_Mark"),
                    .init(icon: "flag.fill", textKey: "AFL_HowTo_Rule_SetShot", diagram: .pitch(tryLine: false)),
                    .init(icon: "scope", textKey: "AFL_HowTo_Rule_Score", diagram: .goalPosts(rugby: false)),
                    .init(icon: "exclamationmark.triangle.fill", textKey: "AFL_HowTo_Rule_Tackle")
                ]
            )
        ),
        GameInfo(
            id: .rugby,
            category: .sport,
            titleKey: "Game_Rugby_Title",
            subtitleKey: "Game_Rugby_Subtitle",
            status: .available,
            systemImage: "figure.rugby",
            accentColor: .orange,
            howToPlay: HowToPlay(
                controls: [
                    .init(icon: "arrow.up.and.down.and.arrow.left.and.right", textKey: "Rugby_HowTo_Control_Move"),
                    .init(icon: "hand.point.up.left.fill", textKey: "Rugby_HowTo_Control_Pass"),
                    .init(icon: "arrow.up", textKey: "Rugby_HowTo_Control_Kick")
                ],
                rules: [
                    .init(icon: "figure.rugby", textKey: "Rugby_HowTo_Rule_Gather"),
                    .init(icon: "flag.checkered", textKey: "Rugby_HowTo_Rule_Try", diagram: .pitch(tryLine: true)),
                    .init(icon: "scope", textKey: "Rugby_HowTo_Rule_Convert", diagram: .goalPosts(rugby: true)),
                    .init(icon: "exclamationmark.triangle.fill", textKey: "Rugby_HowTo_Rule_Tackles"),
                    .init(icon: "hand.draw.fill", textKey: "Rugby_HowTo_Rule_Advanced")
                ]
            )
        ),
        GameInfo(
            id: .connect4,
            category: .board,
            titleKey: "Game_Connect4_Title",
            subtitleKey: "Game_Connect4_Subtitle",
            status: .available,
            systemImage: "circle.grid.3x3.fill",
            accentColor: .blue,
            howToPlay: HowToPlay(
                controls: [
                    .init(icon: "hand.tap.fill", textKey: "Connect4_HowTo_Control_Drop")
                ],
                rules: [
                    .init(icon: "person.2.fill", textKey: "Connect4_HowTo_Rule_Modes"),
                    .init(icon: "dice.fill", textKey: "Connect4_HowTo_Rule_CoinFlip"),
                    .init(icon: "circle.grid.3x3.fill", textKey: "Connect4_HowTo_Rule_Win", diagram: .connectFour)
                ]
            )
        )
    ]

    /// Games in a category, preserving catalog order. Used to build the hub's sections.
    static func games(in category: GameCategory) -> [GameInfo] {
        catalog.filter { $0.category == category }
    }
}
