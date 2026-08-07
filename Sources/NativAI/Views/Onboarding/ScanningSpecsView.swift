/*
 * NativAI - Standalone Local LLM Manager for macOS
 * Copyright (C) 2026 Muhammad Abdul Rafey
 * Licensed under the GNU General Public License v3.0 (GPLv3).
 */

import SwiftUI

struct ScanningSpecsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Checking your system…")
                .font(.title2.bold())

            if appState.deviceSpecs.chipName != "Unknown" && appState.deviceSpecs.totalRAMGB > 0 {
                specsSummary
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Spacer()
        }
        .padding(40)
    }

    private var specsSummary: some View {
        let specs = appState.deviceSpecs
        return VStack(spacing: 8) {
            Text("\(specs.chipName) · \(Int(specs.totalRAMGB)) GB RAM")
                .font(.headline)
            Text("Capability tier: \(specs.tier.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }
}
