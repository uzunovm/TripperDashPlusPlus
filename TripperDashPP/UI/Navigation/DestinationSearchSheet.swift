//
//  DestinationSearchSheet.swift
//  TripperDashPP
//
//  Phase 7b — full-screen sheet with sticky search field + live
//  autocomplete list. Selecting a row resolves it to a Destination
//  and calls `onPick`.
//

import MapKit
import SwiftUI

struct DestinationSearchSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(\.dismiss) private var dismiss

    /// Caller hook. Sheet auto-dismisses after invoking this.
    let onPick: (Destination) -> Void

    /// Optional text to seed the search field with on first appear — used
    /// by "Share to TripperDash++" when a shared link couldn't be geocoded
    /// but yielded a place/road label to look up manually.
    var initialQuery: String? = nil

    @State private var search = LocalSearchService()
    @State private var resolving: Bool = false
    @State private var resolveError: String?
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            List {
                if let err = search.lastError ?? resolveError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if search.query.isEmpty {
                    let recents = status.recentDestinationsStore.items
                    if recents.isEmpty {
                        Section {
                            Label {
                                Text("Start typing an address, city, or place name. Results are biased toward your current location.")
                                    .font(.subheadline)
                            } icon: {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Theme.brandText)
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Theme.brandSoft)
                        } header: {
                            Text("Tip").statLabelStyle()
                        }
                    } else {
                        Section {
                            ForEach(recents) { r in
                                Button {
                                    onPick(r.destination)
                                    status.recentDestinationsStore.record(r.destination)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        IconTile(systemImage: "clock.arrow.circlepath", tint: .secondary,
                                                 background: Theme.surface2, size: 38)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                            if let line = r.addressLine, !line.isEmpty {
                                                Text(line).font(.footnote).foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(minHeight: 52)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        status.recentDestinationsStore.remove(id: r.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("Recent").statLabelStyle()
                                Spacer()
                                Button("Clear") {
                                    status.recentDestinationsStore.clear()
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.brandText)
                                .textCase(nil)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                } else if search.completions.isEmpty && !resolving {
                    Section {
                        Text("No results yet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Identify rows by offset + rendered content, not by the
                // element and not by offset alone. The completer
                // (MKLocalSearchCompleter) rewrites the whole array on every
                // keystroke and can emit content-duplicate rows; keying on the
                // element made SwiftUI's diff see a different item count than
                // it actually inserted into its backing UICollectionView,
                // crashing with "Invalid Number Of Items In Section".
                //
                // Bare offsets fixed the uniqueness half of that but are not
                // STABLE: when the array goes 5 → 3 items, offsets 0/1/2 now
                // address different places, so SwiftUI treats them as the same
                // rows with new content and animates a diff whose endpoints
                // disagree. A crash with this exact signature came back from
                // TestFlight on 1.0.2 (see `LocalSearchService.applyCompletions`
                // for the full report).
                //
                // `CompletionRow.id` therefore folds BOTH in: the offset keeps
                // content-duplicate rows distinct (the original bug), and the
                // title/subtitle make a changed place at the same offset read
                // as a genuinely different row (the new one). Dropping either
                // half reintroduces one of the two crashes.
                ForEach(CompletionRow.rows(from: search.completions)) { row in
                    let c = row.completion
                    Button {
                        Task { await pick(c) }
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(systemImage: "mappin.and.ellipse", size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                if !c.subtitle.isEmpty {
                                    Text(c.subtitle).font(.footnote).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 52)
                    }
                    // .plain stops the List/Form from tinting the whole row
                    // label with the accent colour — otherwise the result
                    // titles render blue (accent) and are hard to read.
                    // Setting .foregroundStyle(.primary) on the Text alone
                    // does NOT override the button tint inside a List.
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(resolving)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $search.query, prompt: "Where to?")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if resolving {
                    ProgressView("Resolving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task {
                // Seed the search bias from current GPS, if available.
                search.biasCenter = status.locationService.lastFix?.coordinate
                // "Share to TripperDash++" fallback: pre-fill the query with
                // the label recovered from an un-geocodable shared link so
                // the rider just picks from the results. Once only.
                if !didSeed, let seed = initialQuery,
                   !seed.trimmingCharacters(in: .whitespaces).isEmpty {
                    search.query = seed
                    didSeed = true
                }
            }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            let dest = try await search.resolve(completion)
            status.recentDestinationsStore.record(dest)
            onPick(dest)
            dismiss()
        } catch {
            resolveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Stable row identity for completer results

/// One autocomplete row, carrying an identity that is BOTH unique within a
/// snapshot AND stable in content — the two properties SwiftUI's `List` diff
/// needs, and which neither `\.self` nor `\.offset` provides on its own.
///
/// `MKLocalSearchCompletion` is a reference type with no usable identity: two
/// results for the same place compare unequal, while genuinely different
/// results can render identically. Keying on the element itself once crashed
/// the app with "Invalid Number Of Items In Section"; keying on bare offsets
/// fixed that but let a changed place reuse a row identity, which is the
/// shape the 1.0.2 TestFlight crash came back in. Combining both closes each
/// other's gap — see the `ForEach` above and
/// `LocalSearchService.applyCompletions`.
private struct CompletionRow: Identifiable {
    let id: String
    let completion: MKLocalSearchCompletion

    static func rows(from completions: [MKLocalSearchCompletion]) -> [CompletionRow] {
        completions.enumerated().map { offset, c in
            CompletionRow(id: "\(offset)\u{1F}\(c.title)\u{1F}\(c.subtitle)", completion: c)
        }
    }
}
