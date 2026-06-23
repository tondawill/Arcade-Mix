//
//  HowToPlayView.swift
//  Arcade Mix
//
//  Reusable "How to Play" sheet for any game: lists the game's controls and main rules
//  from its `GameInfo.howToPlay`. Opened from the "?" button in each game's menu, so every
//  game (current and future) gets player-facing help with no per-screen code.
//

import SwiftUI

struct HowToPlayView: View {
    let info: GameInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(title: "HowToPlay_Controls", items: info.howToPlay.controls)
                    section(title: "HowToPlay_Rules", items: info.howToPlay.rules)
                    if !info.howToPlay.difficulty.isEmpty {
                        difficultySection(info.howToPlay.difficulty)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text("HowToPlay_Title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Common_Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: LocalizedStringResource, items: [HowToPlay.Item]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())

            ForEach(items) { item in
                if let diagram = item.diagram {
                    // A drawn illustration banner above the rule text.
                    VStack(alignment: .leading, spacing: 10) {
                        RuleDiagramView(diagram: diagram, accent: info.accentColor)
                            .frame(height: 130)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Text(item.textKey)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // Icon + text row.
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.headline)
                            .foregroundStyle(info.accentColor)
                            .frame(width: 28)
                        Text(item.textKey)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// A two-column table — score milestone on the left, what ramps up on the right — so the
    /// player can see how the game escalates as they score.
    @ViewBuilder
    private func difficultySection(_ steps: [HowToPlay.DifficultyStep]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HowToPlay_Difficulty")
                .font(.title2.bold())

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 14) {
                ForEach(steps) { step in
                    GridRow {
                        Text(step.whenKey)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(info.accentColor)
                            .gridColumnAlignment(.leading)
                        Text(step.effectKey)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
