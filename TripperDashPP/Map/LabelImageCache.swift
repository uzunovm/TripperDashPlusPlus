//
//  LabelImageCache.swift
//  TripperDashPP
//
//  CoreText label bitmaps for the vector map: each name is measured and
//  rendered once (text + halo) and then blitted at integer pixels every
//  frame, so a label that stays put has identical pixels frame to frame —
//  nothing new for the encoder to spend bits on. CPU-only (CoreText into a
//  bitmap CGContext), background-safe.
//
//  Text goes through `dashSafe` like every other overlay string (the
//  project's ASCII policy for dash text).
//

import CoreGraphics
import CoreText
import UIKit

final class LabelImageCache {
    struct Entry {
        let size: CGSize
        var image: CGImage?
    }

    /// Halo width (px) around each glyph.
    static let halo: CGFloat = 2
    /// Cleared wholesale above this many entries (a ride passes a few
    /// hundred names; rebuilding one is ~0.1 ms).
    static let capacity = 400

    private var entries: [String: Entry] = [:]

    private func key(_ l: VectorLabel, dark: Bool) -> String {
        "\(dark ? "d" : "l")|\(l.kind.rawValue)|\(l.text)"
    }

    static func font(for kind: VectorLabel.Kind) -> UIFont {
        switch kind {
        case .city: return .systemFont(ofSize: 15, weight: .bold)
        case .town: return .systemFont(ofSize: 13, weight: .bold)
        case .village, .suburb: return .systemFont(ofSize: 12, weight: .semibold)
        case .locality: return .systemFont(ofSize: 11, weight: .medium)
        case .road: return .systemFont(ofSize: 11, weight: .semibold)
        case .roadRef: return .systemFont(ofSize: 11, weight: .bold)
        case .water:
            let base = UIFont.systemFont(ofSize: 11, weight: .medium)
            let italic = base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor
            return UIFont(descriptor: italic, size: 11)
        }
    }

    private func line(_ l: VectorLabel, palette: VectorPalette, stroke: Bool) -> CTLine {
        let major = l.kind == .city || l.kind == .town
        let font = Self.font(for: l.kind)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if stroke {
            // strokeWidth is % of the font size and straddles the outline:
            // 2 × halo of it lands outside the glyph.
            attrs[.strokeWidth] = 2 * Self.halo / font.pointSize * 100
            attrs[.strokeColor] = UIColor(cgColor: palette.labelHalo)
        } else {
            attrs[.foregroundColor] = UIColor(cgColor: major ? palette.majorLabelInk : palette.labelInk)
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: l.text.dashSafe, attributes: attrs))
    }

    /// Image size for a label (halo included); nil for an empty name.
    func size(_ l: VectorLabel, palette: VectorPalette, dark: Bool) -> CGSize? {
        let k = key(l, dark: dark)
        if let e = entries[k] { return e.size }
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        let ln = line(l, palette: palette, stroke: false)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(ln, &ascent, &descent, nil))
        guard w > 0 else { return nil }
        let pad = Self.halo + 1
        let size = CGSize(width: ceil(w + 2 * pad), height: ceil(ascent + descent + 2 * pad))
        entries[k] = Entry(size: size, image: nil)
        return size
    }

    /// The label's bitmap (top row first), rendered on first use.
    func image(_ l: VectorLabel, palette: VectorPalette, dark: Bool) -> CGImage? {
        let k = key(l, dark: dark)
        guard let size = entries[k]?.size ?? self.size(l, palette: palette, dark: dark) else { return nil }
        if let img = entries[k]?.image { return img }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let fill = line(l, palette: palette, stroke: false)
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(fill, nil, &descent, nil)
        let pad = Self.halo + 1
        ctx.setShouldAntialias(true)
        ctx.setLineJoin(.round)
        ctx.textMatrix = .identity
        // Bitmap is y-up: baseline sits `pad + descent` above the bottom.
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line(l, palette: palette, stroke: true), ctx)
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(fill, ctx)
        let img = ctx.makeImage()
        entries[k]?.image = img
        return img
    }

    func removeAll() { entries.removeAll() }
}
