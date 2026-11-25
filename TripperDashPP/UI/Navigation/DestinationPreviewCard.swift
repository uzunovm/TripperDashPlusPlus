//
//  DestinationPreviewCard.swift
//  TripperDashPP
//
//  Compact, non-modal preview of a selected destination (June 2026
//  redesign). Replaces the old `DestinationPreviewSheet` modal.
//
//  Why an inline overlay instead of a `.sheet`:
//   - A modal sheet (even at `.medium`) covers ~half the map and, more
//     importantly, BLOCKS the map underneath — the rider couldn't tap a
//     nearby point to retarget without first dismissing the card.
//   - This card floats at the bottom over a still-live map. Long-pressing
//     another point on the map just re-seeds the card with the new
//     coordinate (handled by the parent's `onTap`), so "pick something,
//     then nudge to a neighbour" is one fluid gesture.
//
//  Layout: a single rounded card pinned to the bottom safe area. Title
//  + address on top, a tight action row below: "Add to favorites" (shown
//  as a non-tappable "Saved" label when the place is already a favorite)
//  and "Routes", which starts route planning. Deliberately short so the
//  map dominates.
//

import CoreLocation
import SwiftUI

struct DestinationPreviewCard: View {
    @Environment(NavigationStore.self) private var store

    let destination: Destination
    /// Begin route planning to this destination.
    let onCalculateRoutes: (Destination) -> Void
    /// Open the favorite editor seeded with this destination.
    let onAddToFavorites: (Destination) -> Void
    /// Dismiss the card (clears the selection in the parent).
    let onClose: () -> Void

    private var alreadyFavorited: Bool { store.isFavorited(destination) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name/address + close.
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: alreadyFavorited
                         ? (store.matchingFavorite(for: destination)?.resolvedIconSymbol ?? "star.fill")
                         : "mappin.and.ellipse",
                         size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    if let addr = destination.addressLine, !addr.isEmpty {
                        Text(addr)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(String(format: "%.5f, %.5f",
                                    destination.coordinate.latitude,
                                    destination.coordinate.longitude))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.surface2, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -8)
                .padding(.trailing, -8)
                .accessibilityLabel("Close")
            }

            // Action row.
            HStack(spacing: 8) {
                if alreadyFavorited {
                    Label("Saved", systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.surface2, in: Capsule())
                } else {
                    Button {
                        onAddToFavorites(destination)
                    } label: {
                        Label("Add to favorites", systemImage: "star")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(SecondaryCTAButtonStyle())
                }

                Button {
                    onCalculateRoutes(destination)
                } label: {
                    Label("Routes", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.subheadline.weight(.bold))
                }
                .buttonStyle(PrimaryCTAButtonStyle())
                .frame(height: 50)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 28)
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
