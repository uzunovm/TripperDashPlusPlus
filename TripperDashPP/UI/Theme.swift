//
//  Theme.swift
//  TripperDashPP
//
//  Shared look of the phone UI (2026 redesign): one signal-orange brand
//  colour on a graphite / light-grey ground, material panels floating over
//  the map, large tap targets. Every colour adapts to the system Light /
//  Dark appearance — there is no in-app theme switch.
//
//  Kept deliberately small: a handful of colour tokens, three button
//  styles and two card modifiers. Screens compose these; nothing here
//  carries behaviour.
//

import SwiftUI
import UIKit

enum Theme {
    // MARK: Colours

    /// Brand fill for primary CTAs, the maneuver tile and route lines.
    /// Same in both appearances; text on it is `onBrand` (dark), which
    /// reads at ~8:1 — white on this orange would not.
    static let brand = Color(hex: 0xFF8A1F)
    static let onBrand = Color(hex: 0x1A0D00)
    /// Brand used as TEXT / icon tint on a plain surface: darker in light
    /// mode so it keeps 4.5:1 on white.
    static let brandText = dynamic(light: 0xB24C00, dark: 0xFF9A3D)
    /// Low-alpha brand wash behind tinted secondary buttons and icon tiles.
    static let brandSoft = Color(hex: 0xFF8A1F).opacity(0.16)

    static let background = dynamic(light: 0xF2F3F5, dark: 0x0B0D10)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x15181D)
    static let surface2 = dynamic(light: 0xEEF0F3, dark: 0x1F232A)
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.08)
        : UIColor(white: 0.05, alpha: 0.08) })

    static let ok = dynamic(light: 0x14A35A, dark: 0x3DDC84)
    static let connected = dynamic(light: 0x1F6FE0, dark: 0x4C9BFF)
    static let warn = dynamic(light: 0xB87900, dark: 0xFFC53D)
    static let danger = dynamic(light: 0xC42F25, dark: 0xFF6B5F)

    // MARK: Metrics

    /// Height of a full-width primary CTA. Big on purpose: glanced at and
    /// tapped with gloves.
    static let ctaHeight: CGFloat = 56
    static let cardRadius: CGFloat = 24

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Button styles

/// Full-width capsule CTA filled with the brand orange.
struct PrimaryCTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Theme.onBrand : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: Theme.ctaHeight)
            .background(isEnabled ? Theme.brand : Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.25 : 0), lineWidth: 1).blendMode(.overlay))
            .shadow(color: Theme.brand.opacity(isEnabled ? 0.3 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Full-width capsule on a neutral surface; `tint` colours the label and
/// adds a matching wash (e.g. `Theme.danger` for Disconnect / Cancel).
struct SecondaryCTAButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint ?? Color.primary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background {
                Capsule().fill(tint.map { $0.opacity(0.14) } ?? Theme.surface2)
            }
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 44-pt round icon button on material — the header and map buttons.
struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Cards

extension View {
    /// Material panel floating over the map.
    func glassCard(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    /// Opaque card on the screen background (HUD, lists).
    func solidCard(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// Small uppercase tracking label ("MOVING", "ETA").
    func statLabelStyle() -> some View {
        self
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// Rounded-square icon tile used in front of list rows and cards.
struct IconTile: View {
    let systemImage: String
    var tint: Color = Theme.brandText
    var background: Color = Theme.brandSoft
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}
