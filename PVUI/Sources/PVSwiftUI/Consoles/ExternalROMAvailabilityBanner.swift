//
//  ExternalROMAvailabilityBanner.swift
//  Provenance
//

import SwiftUI
import Combine
import PVFileSystem

/// Shows a single library-wide notice when the selected in-place ROM folder is unavailable.
struct ExternalROMAvailabilityBanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = ExternalROMFolderAvailability.notConfigured

    private static let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if case .unavailable(let displayName) = availability {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.fill.badge.xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("\(displayName) is unavailable. Connect the drive or reselect the folder in Files.")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.18))
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear(perform: refreshAvailability)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshAvailability() }
        }
        .onReceive(Self.refreshTimer) { _ in refreshAvailability() }
    }

    private func refreshAvailability() {
        availability = ExternalROMFolderAvailability.current()
    }
}
