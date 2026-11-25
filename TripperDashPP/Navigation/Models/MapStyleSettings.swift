//
//  MapStyleSettings.swift
//  TripperDashPP
//
//  Persisted user preference for the map appearance: Light, Dark, or
//  Auto (follow local sunrise/sunset). This is the USER-FACING knob —
//  distinct from `MapStyle` (the resolved palette the renderer actually
//  paints). `MapStyleResolver` turns this mode + the live GPS fix + the
//  clock into a concrete `MapStyle`.
//
//  Storage mirrors `DashNavSettings`: a small Codable blob in
//  UserDefaults under a versioned key, observable so the settings UI and
//  the render pipeline react immediately when the rider changes it.
//

import Foundation
import Observation

@Observable
final class MapStyleSettings {

    /// What the rider picked in Settings → Map → Appearance.
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case light
        case dark
        case auto

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Light"
            case .dark:  return "Dark"
            case .auto:  return "Auto (sunrise/sunset)"
            }
        }
    }

    /// Default Auto — the whole point of the feature is hands-off
    /// day/night switching; riders who want a fixed palette pick it
    /// explicitly.
    var mode: Mode = .auto {
        didSet { persist() }
    }

    /// Settings → Map → 3D map: the dash map tilted towards the direction
    /// of travel (`DashPerspective`). Default on.
    var perspective = true {
        didSet { persist() }
    }

    /// Settings → Map → Map renderer.
    enum Renderer: String, Codable, CaseIterable, Identifiable {
        /// OpenMapTiles vector tiles drawn every frame (`VectorMapRenderer`).
        case vector
        /// Pre-baked OSM Carto raster composites (`RouteTileCache`).
        case raster

        var id: String { rawValue }

        var label: String {
            switch self {
            case .vector: return "Vector"
            case .raster: return "Raster (classic)"
            }
        }
    }

    /// Default Vector: sharp roads at any rotation, upright labels.
    var renderer: Renderer = .vector {
        didSet { persist() }
    }

    /// Settings → Map → Smooth position: snap the rider to the route and
    /// predict between GPS fixes (`PositionPredictor`). Default on.
    var smoothPosition = true {
        didSet { persist() }
    }

    // MARK: - Persistence

    private static let storeKey = "mapStyleSettings.v1"

    private struct Persisted: Codable {
        var mode: Mode
        // Optional: blobs saved before the 3D toggle lack it (→ on).
        var perspective: Bool?
        // Optional: blobs saved before these settings existed (→ defaults).
        var renderer: Renderer?
        var smoothPosition: Bool?
    }

    init() {
        load()
    }

    private func load() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: raw)
        else { return }
        self.mode = p.mode
        self.perspective = p.perspective ?? true
        self.renderer = p.renderer ?? .vector
        self.smoothPosition = p.smoothPosition ?? true
    }

    private func persist() {
        if let raw = try? JSONEncoder().encode(Persisted(mode: mode, perspective: perspective,
                                                          renderer: renderer, smoothPosition: smoothPosition)) {
            UserDefaults.standard.set(raw, forKey: Self.storeKey)
        }
    }
}
