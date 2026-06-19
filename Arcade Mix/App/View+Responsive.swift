//
//  View+Responsive.swift
//  Arcade Mix
//
//  Small layout helpers for responsive text. On narrow / Home-button devices (e.g. the
//  iPhone SE) headline and button text can overflow; these keep it on one line but let it
//  scale down to fit instead of truncating with "…".
//

import SwiftUI

extension View {
    /// Keep text on a single line, shrinking it down to `minScale` of its font size to fit
    /// the available width (no "…" truncation). Use for titles, buttons, and status chips.
    func shrinkToFit(_ minScale: CGFloat = 0.6) -> some View {
        self.lineLimit(1).minimumScaleFactor(minScale)
    }
}
