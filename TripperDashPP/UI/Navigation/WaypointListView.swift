//
//  WaypointListView.swift
//  TripperDashPP
//
//  feat/route-waypoints — the stop list for a multi-stop plan.
//
//  Drag-to-reorder, swipe-to-delete, and an "Add stop" affordance,
//  bound to the live @Observable PlannedRoute. Every mutation returns
//  the minimal set of dirty leg indices; this view forwards them to
//  `onRecompute` so only the affected legs hit MKDirections.
//
//  In the planner it pairs with PlanningMapView (shares the same
//  PlannedRoute instance), so reordering here redraws the map and
//  vice-versa with no manual sync. EditRouteSheet reuses the list without
//  a map, with the origin row pinned (`pinsOrigin`).
//

import SwiftUI

struct WaypointListView: View {
    /// The live plan. Mutated in place; @Observable propagates to the
    /// map + totals.
    @Bindable var plan: PlannedRoute

    /// Fired with the dirty leg indices after any structural mutation.
    /// The owner runs RoutingService.recompute for exactly these legs.
    let onRecompute: (Set<Int>) -> Void

    /// Fired when the user taps "Add stop" — owner presents the search
    /// sheet and, on pick, inserts the waypoint (the planner then triggers a
    /// recompute; the mid-ride editor defers routing to Apply).
    let onAddStop: () -> Void

    /// Leg indices currently being recomputed — shows a spinner on the
    /// affected rows. Owner updates this around the async recompute.
    var recomputingLegs: Set<Int> = []

    /// Keep row 0 (the live-position origin) first and undeletable — the
    /// mid-ride editor, where it's where the rider IS, not a stop.
    var pinsOrigin: Bool = false

    var body: some View {
        List {
            Section {
                ForEach(plan.waypoints) { wp in
                    let index = plan.waypoints.firstIndex(of: wp) ?? 0
                    waypointRow(index: index, waypoint: wp)
                        .moveDisabled(pinsOrigin && index == 0)
                        .deleteDisabled(pinsOrigin && index == 0)
                }
                .onMove(perform: moveRows)
                .onDelete(perform: deleteRows)
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Stops")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if plan.isComputed {
                        Text("\(plan.totalDistanceDisplay) · \(plan.totalTravelTimeDisplay)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .textCase(nil)
            }

            Section {
                Button {
                    onAddStop()
                } label: {
                    Label {
                        Text("Add stop").font(.body.weight(.semibold)).foregroundStyle(Theme.brandText)
                    } icon: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Theme.brandText)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.editMode, .constant(.active))  // always reorder-enabled
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    // MARK: - Row

    @ViewBuilder
    private func waypointRow(index: Int, waypoint wp: Waypoint) -> some View {
        HStack(spacing: 12) {
            stopBadge(index: index)
            VStack(alignment: .leading, spacing: 2) {
                Text(wp.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let addr = wp.addressLine, !addr.isEmpty {
                    Text(addr)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Leg summary for the segment LEAVING this stop (not the
                // final destination, which has no outgoing leg).
                if index < plan.legs.count {
                    legSummary(forLegIndex: index)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Badge: location glyph for the origin, numbered intermediate stops,
    /// checkered flag for the destination.
    @ViewBuilder
    private func stopBadge(index: Int) -> some View {
        let isOrigin = index == 0
        let isDestination = index == plan.waypoints.count - 1
        ZStack {
            Circle()
                .fill(isOrigin ? Theme.ok.opacity(0.18) : (isDestination ? Theme.brand : Theme.surface2))
                .frame(width: 32, height: 32)
            if isOrigin {
                Image(systemName: "location.fill").font(.caption.weight(.bold))
                    .foregroundStyle(Theme.ok)
            } else if isDestination {
                Image(systemName: "flag.checkered").font(.caption.weight(.bold))
                    .foregroundStyle(Theme.onBrand)
            } else {
                Text("\(index)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func legSummary(forLegIndex i: Int) -> some View {
        if recomputingLegs.contains(i) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Recalculating…").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let opt = plan.legs[i].selected {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if !opt.summary.isEmpty {
                        Text(opt.summary)
                    }
                    Text(opt.travelTimeDisplay)
                    Text("·")
                    Text(opt.distanceDisplay)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if opt.violatesFilter {
                    Label(opt.violatesHighwayFilter ? "No non-highway route — using highway" : "No toll-free route — using toll road",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            // Mid-ride editor: legs are routed on Apply, not as you edit.
            Text(pinsOrigin ? "Calculated on Apply" : "No route yet")
                .font(.caption2)
                .foregroundStyle(pinsOrigin ? Color.secondary : Color.orange)
        }
    }

    // MARK: - Mutations

    private func moveRows(from source: IndexSet, to destination: Int) {
        guard let src = source.first else { return }
        // SwiftUI's onMove destination is the post-removal insertion
        // slot; PlannedRoute.moveWaypoint expects the same semantics as
        // Array.move, so translate.
        let dest = destination > src ? destination - 1 : destination
        // A stop dropped above the pinned origin would ride before "here".
        if pinsOrigin && dest == 0 { return }
        let dirty = plan.moveWaypoint(from: src, to: dest)
        if !dirty.isEmpty { onRecompute(dirty) }
    }

    private func deleteRows(at offsets: IndexSet) {
        // Collect ids first (indices shift as we remove).
        let ids = offsets.compactMap { plan.waypoints.indices.contains($0) ? plan.waypoints[$0].id : nil }
        var dirty = Set<Int>()
        for id in ids {
            dirty.formUnion(plan.removeWaypoint(id: id))
        }
        if !dirty.isEmpty { onRecompute(dirty) }
    }
}
