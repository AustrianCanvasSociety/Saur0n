// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os
import Saur0nCore

/// The Dock icon (Phase 6 Step 9): the eye in flames over a tile stepped along option 1 of amulet `saur0n-dock-load`,
/// "Red only", with the CPU border inside the tile's edge, and the "!" badge while a warning is in force. Set only when
/// the step, border or badge changed (the overhead budget); back to the bundle's icon at quit. Each change is logged
/// once (`app.saur0n.monitor`, category `dock`), which the live check `dock --window` reads: the tile's image cannot be
/// read from the Dock.
@MainActor
final class DockIcon {
    /// The tile's colours, step 1 (the bundle icon's) to 5 (plan § Decisions; the user: "1, original").
    static let ramp: [UInt32] = [0x101015, 0x3a0d10, 0x5e0b0f, 0x80090d, 0xa30a0e]
    /// Orange thinner at 80%, red thicker at 90%, in the 512-point design space (the page's `BORDERS`).
    static let borders: [DockLevel.Border: (color: UInt32, width: CGFloat)] = [
        .orange: (0xff992d, 22), .red: (0xff3b30, 38),
    ]
    static let pixels = 1024

    private var shown = DockLevel.State()
    private var badge = false
    /// The bundle's icon, kept before the first change and put back at quit.
    private var bundleIcon: NSImage?
    private lazy var eye: CGImage? = Bundle.main.url(forResource: "AppIcon-eye", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    private let log = Logger(subsystem: "app.saur0n.monitor", category: "dock")

    init() {
        // The model lives as long as the app, so the observer is never removed.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    func show(_ state: DockLevel.State, badge: Bool) {
        guard state != shown || badge != self.badge else { return }
        let app = NSApplication.shared
        if state.step != shown.step || state.border != shown.border {
            if bundleIcon == nil { bundleIcon = app.applicationIconImage }
            if state.step == 1 && state.border == .none {
                app.applicationIconImage = bundleIcon
            } else if let image = image(state) {
                app.applicationIconImage = image
            }
        }
        if badge != self.badge { app.dockTile.badgeLabel = badge ? "!" : nil }
        shown = state
        self.badge = badge
        log.notice("""
            dock step=\(state.step) cpu=\(state.cpuStep) memory=\(state.memoryStep) \
            border=\(state.border.rawValue, privacy: .public) badge=\(badge ? 1 : 0)
            """)
    }

    private func reset() {
        let app = NSApplication.shared
        if let bundleIcon { app.applicationIconImage = bundleIcon }
        app.dockTile.badgeLabel = nil
    }

    /// The tile as `scripts/make-icon.swift` draws it — the step's colour lightened 8% at the top to darkened 55% at the
    /// bottom, clipped to the rounded square — then the eye, then the border; nil without the eye's image.
    private func image(_ state: DockLevel.State) -> NSImage? {
        guard let eye, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Self.pixels, height: Self.pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(Self.pixels) / 512
        // The design space has y down, as the page's SVG; flip once.
        let design = CGAffineTransform(translationX: 0, y: CGFloat(Self.pixels)).scaledBy(x: s, y: -s)
        ctx.concatenate(design)
        let tile = Self.channels(Self.ramp[min(max(state.step, 1), Self.ramp.count) - 1])
        let top = tile.map { ($0 + (255 - $0) * 0.08).rounded() }, bottom = tile.map { ($0 * 0.45).rounded() }
        let square = CGPath(roundedRect: CGRect(x: 26, y: 26, width: 460, height: 460), cornerWidth: 104,
                            cornerHeight: 104, transform: nil)
        ctx.saveGState()
        ctx.addPath(square)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [Self.color(top), Self.color(bottom)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 26), end: CGPoint(x: 0, y: 486), options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.concatenate(design.inverted())
        ctx.draw(eye, in: CGRect(x: 0, y: 0, width: Self.pixels, height: Self.pixels))
        ctx.restoreGState()
        if let border = Self.borders[state.border] {
            let w = border.width
            ctx.addPath(CGPath(roundedRect: CGRect(x: 26 + w / 2, y: 26 + w / 2, width: 460 - w, height: 460 - w),
                               cornerWidth: 104 - w / 2, cornerHeight: 104 - w / 2, transform: nil))
            ctx.setStrokeColor(Self.color(Self.channels(border.color)))
            ctx.setLineWidth(w)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }

    private static func channels(_ v: UInt32) -> [CGFloat] {
        [CGFloat((v >> 16) & 0xff), CGFloat((v >> 8) & 0xff), CGFloat(v & 0xff)]
    }

    private static func color(_ c: [CGFloat]) -> CGColor { CGColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1) }
}
