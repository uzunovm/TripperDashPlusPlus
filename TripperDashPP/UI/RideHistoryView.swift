//
//  RideHistoryView.swift
//  TripperDashPP
//
//  "Ride history" sheet (picker toolbar, idle state only): every ride of
//  the last `RideHistoryStore.retentionDays` days, newest first. Tap a
//  ride for its map + totals, save it to Saved routes, or export it as
//  GPX — the post-arrival trip panel's save, plus export, for rides
//  that weren't saved on the spot. Swipe to delete.
//

import SwiftUI

struct RideHistoryView: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    private var history: RideHistoryStore { status.rideHistory }
    /// Once per presentation — the root's appear also fires on every pop
    /// back from a detail view.
    @State private var loaded = false
    private var imperial: Bool { status.dashNavSettings.units == .imperial }
    private var useCommaDecimal: Bool { status.dashNavSettings.decimalSeparator == .comma }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if history.rides.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Every ride is kept here for \(RideHistoryStore.retentionDays) days.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(history.rides, id: \.startedAt) { ride in
                                NavigationLink {
                                    RideHistoryDetailView(ride: ride)
                                } label: {
                                    row(ride)
                                }
                            }
                            .onDelete { offsets in
                                let doomed = offsets.map { history.rides[$0] }
                                doomed.forEach { history.delete($0) }
                            }
                        } footer: {
                            Text("Rides are kept for \(RideHistoryStore.retentionDays) days. Save one to your routes to keep it.")
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle("Ride history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard !loaded else { return }
                await history.load()
                loaded = true
            }
        }
    }

    private func row(_ ride: RideStats) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "point.topleft.down.to.point.bottomright.curvepath", size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.startedAt ?? .distantPast,
                     format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.body.weight(.semibold))
                Text("\(RideStatsFormatting.duration(ride.movingSeconds)) moving · avg \(RideStatsFormatting.speed(ride.averageSpeedMps, imperial: imperial))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(RideStatsFormatting.distance(ride.distanceMeters, imperial: imperial, useCommaDecimal: useCommaDecimal))
                .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}

private struct RideHistoryDetailView: View {
    @Environment(AppStatus.self) private var status

    let ride: RideStats
    /// Built once, when the detail is shown — NOT in init: the list's
    /// NavigationLink builds every visible row's destination on each list
    /// render, and mapping thousands of track points there is wasted.
    /// Fresh point ids on every body pass would also re-snapshot the
    /// preview map. nil until built, and for a ride with no track.
    @State private var route: SavedRoute?
    @State private var exportURL: URL?

    /// Already in Saved routes (from here, a reopen, or the trip panel's
    /// "Save ride" — same default name). A renamed copy isn't matched.
    private var isSaved: Bool {
        guard let route else { return false }
        return status.savedRoutesStore.routes.contains { $0.kind == .track && $0.name == route.name }
    }

    private var imperial: Bool { status.dashNavSettings.units == .imperial }
    private var useCommaDecimal: Bool { status.dashNavSettings.decimalSeparator == .comma }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let route {
                    SavedRoutePreviewMap(points: route.points)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Distance").statLabelStyle()
                    Spacer()
                    Text(RideStatsFormatting.distance(ride.distanceMeters, imperial: imperial, useCommaDecimal: useCommaDecimal))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                }
                .padding(16)
                .solidCard(cornerRadius: 20)
                .accessibilityElement(children: .combine)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    tile("Moving", RideStatsFormatting.duration(ride.movingSeconds))
                    tile("Elapsed", RideStatsFormatting.duration(ride.elapsedSeconds))
                    tile("Ascent", "≈ " + RideStatsFormatting.elevation(ride.elevationGainMeters, imperial: imperial))
                    tile("Avg", RideStatsFormatting.speed(ride.averageSpeedMps, imperial: imperial))
                    tile("Max", RideStatsFormatting.speed(ride.maxSpeedMps, imperial: imperial))
                }

                if let route {
                    VStack(spacing: 8) {
                        Button {
                            guard !isSaved else { return }
                            status.savedRoutesStore.add(route)
                        } label: {
                            Label(isSaved ? "Saved to routes" : "Save to routes",
                                  systemImage: isSaved ? "checkmark.circle.fill" : "bookmark")
                        }
                        .buttonStyle(PrimaryCTAButtonStyle())
                        .disabled(isSaved)

                        if let url = exportURL {
                            ShareLink(item: url) {
                                Label("Export as GPX", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(SecondaryCTAButtonStyle(height: 52))
                        } else {
                            Button {
                                exportURL = SavedRouteDetailView.writeGPX(route)
                            } label: {
                                Label("Export as GPX", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(SecondaryCTAButtonStyle(height: 52))
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(Text(ride.startedAt ?? .distantPast, format: .dateTime.day().month(.abbreviated).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if route == nil { route = RideStatsService.savedRoute(from: ride) }
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).statLabelStyle()
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .solidCard(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}
