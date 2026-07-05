//
//  PauseControls.swift
//  Arcade Mix
//
//  Shared in-game pause UI reused by every real-time game (AFL, Rugby, Brick Breaker,
//  Snake). A HUD pause button styled to match the other HUD capsules, and a "Paused"
//  overlay offering Resume / Restart / Main Menu. Each game owns its own pause state and
//  wires these two pieces to it.
//

import SwiftUI

/// A pause button styled to match the in-game HUD capsules. Shown while a game is running.
struct HUDPauseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pause.fill")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(Text("Common_Pause"))
    }
}

/// The mid-game "Paused" overlay: a dark scrim over a card with Resume, Restart, and
/// Main Menu. Mirrors the Game Over panel's styling so the two read as a set.
struct PausedOverlay: View {
    let onResume: () -> Void
    let onRestart: () -> Void
    let onMainMenu: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Common_Paused")
                    .font(.largeTitle.bold())
                    .minimumScaleFactor(0.7)

                Button(action: onResume) {
                    Label("Common_Resume", systemImage: "play.fill")
                        .bold().shrinkToFit().frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)

                HStack(spacing: 16) {
                    Button(action: onRestart) {
                        Text("Common_Restart").shrinkToFit().frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onMainMenu) {
                        Text("Common_MainMenu").shrinkToFit().frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(radius: 20)
            .padding(.horizontal, 24)
        }
    }
}
