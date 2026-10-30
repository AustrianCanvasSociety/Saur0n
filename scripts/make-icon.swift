// SPDX-License-Identifier: GPL-3.0-or-later
// Draws Saur0n's icon — the eye in flames (variant A6), in the user's final colours (2026-10-20) — into an
// iconset: every size `iconutil` wants, at 1× and 2×. The geometry is the one the colour page draws as SVG
// (~/Dev/Amulets/pages/saur0n-icon-colors.html), in a 512-point design space with y pointing down.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.iconset   (scripts/make-app.sh runs iconutil on it; the
// tileless eye goes beside it, Resources/AppIcon-eye.png, which make-app.sh copies into the bundle)
import AppKit
import CoreImage
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let out = args.first else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <AppIcon.iconset dir>\n".utf8))
    exit(2)
}

// MARK: Colours

typealias RGB = (r: Double, g: Double, b: Double)

func hex(_ v: UInt32) -> RGB { (Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)) }
/// The page's `mix` and `darken`, rounded to whole channel values as its hex strings are.
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    ((a.r + (b.r - a.r) * t).rounded(), (a.g + (b.g - a.g) * t).rounded(), (a.b + (b.b - a.b) * t).rounded())
}
func darken(_ a: RGB, _ t: Double) -> RGB { ((a.r * (1 - t)).rounded(), (a.g * (1 - t)).rounded(), (a.b * (1 - t)).rounded()) }
func cg(_ c: RGB, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
}

let white = hex(0xffffff)
let tile = hex(0x101015), flameOuter = hex(0xf24c18), flameInner = hex(0xff992d), glow = hex(0xff0000)
let irisCentre = hex(0x000000), irisRim = hex(0xc85f1c), rim = hex(0xffa450)
let pupil = hex(0x000000), pupilFire = hex(0xc82400)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Paths

/// The eye's outline: two cubic curves meeting at the corners (48, 256) and (464, 256).
let eye: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 48, y: 256))
    p.addCurve(to: CGPoint(x: 464, y: 256), control1: CGPoint(x: 140, y: 120), control2: CGPoint(x: 372, y: 120))
    p.addCurve(to: CGPoint(x: 48, y: 256), control1: CGPoint(x: 372, y: 392), control2: CGPoint(x: 140, y: 392))
    p.closeSubpath()
    return p
}()

/// The pupil: a vertical slit, 44 wide and 192 tall.
let pupilSlit: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 256, y: 160))
    p.addCurve(to: CGPoint(x: 278, y: 256), control1: CGPoint(x: 272, y: 160), control2: CGPoint(x: 278, y: 208))
    p.addCurve(to: CGPoint(x: 256, y: 352), control1: CGPoint(x: 278, y: 304), control2: CGPoint(x: 272, y: 352))
    p.addCurve(to: CGPoint(x: 234, y: 256), control1: CGPoint(x: 240, y: 352), control2: CGPoint(x: 234, y: 304))
    p.addCurve(to: CGPoint(x: 256, y: 160), control1: CGPoint(x: 234, y: 208), control2: CGPoint(x: 240, y: 160))
    p.closeSubpath()
    return p
}()

/// The flames round the eye: `n` tongues along each lid (tips on the curve, valleys as quadratic control
/// points), long and short alternating by `alt`. Toward the corners the tongues shorten to 35 % of `reach`
/// and sweep along the lid, so the fire comes to a point at each corner.
func flamePath(n: Int = 16, tight: Double = 8, reach: Double = 56, alt: Double = 0.65) -> CGPath {
    let m = 2 * n
    var top: [CGPoint] = []
    for k in 0...m {
        let u = -1 + 2 * Double(k) / Double(m)
        let x = 256 + 208 * u, y = 256 - 102 * (1 - u * u)
        let len = (208 * 208 + 204 * u * 204 * u).squareRoot()
        let t = (208 / len, 204 * u / len), nrm = (204 * u / len, -208 / len)
        let tip = k % 2 == 1
        let taper = 0.35 + 0.65 * (1 - u * u)
        let d = tip ? reach * taper * ((k / 2) % 2 == 1 ? alt : 1) : tight
        let l = tip ? reach * 0.6 * u : 0    // the page's reach · 0.6 · |u| · sign(u)
        top.append(CGPoint(x: x + nrm.0 * d + t.0 * l, y: y + nrm.1 * d + t.1 * l))
    }
    let bottom = Array(top.map { CGPoint(x: $0.x, y: 512 - $0.y) }.reversed())
    let cornerL = CGPoint(x: 48 - tight * 1.4, y: 256), cornerR = CGPoint(x: 464 + tight * 1.4, y: 256)
    let p = CGMutablePath()
    p.move(to: cornerL)
    func run(_ pts: [CGPoint], to end: CGPoint) {
        var k = 1
        while k < pts.count { p.addQuadCurve(to: pts[k], control: pts[k - 1]); k += 2 }
        p.addQuadCurve(to: end, control: pts[pts.count - 1])
    }
    run(top, to: cornerR)
    run(bottom, to: cornerL)
    p.closeSubpath()
    return p
}

/// A small fire fringe round the pupil in the eye flames' style, hugging an ellipse 22 × 96.
func pupilFlamePath(n: Int = 20, tight: Double = 2, reach: Double = 11, alt: Double = 0.7) -> CGPath {
    let rx = 22.0, ry = 96.0, m = 2 * n
    var pts: [CGPoint] = []
    for k in 0..<m {
        let a = Double(k) / Double(m) * 2 * .pi
        let bx = 256 + rx * sin(a), by = 256 - ry * cos(a)
        let nx = sin(a) / rx, ny = -cos(a) / ry, len = (nx * nx + ny * ny).squareRoot()
        let d = k % 2 == 1 ? tight : reach * ((k / 2) % 2 == 1 ? alt : 1)
        pts.append(CGPoint(x: bx + nx / len * d, y: by + ny / len * d))
    }
    let p = CGMutablePath()
    p.move(to: pts[0])
    var k = 1
    while k < m { p.addQuadCurve(to: pts[(k + 1) % m], control: pts[k]); k += 2 }
    p.closeSubpath()
    return p
}

let flame = flamePath(), pupilFlame = pupilFlamePath()
let square = CGPath(roundedRect: CGRect(x: 26, y: 26, width: 460, height: 460), cornerWidth: 104, cornerHeight: 104,
                    transform: nil)

// MARK: Drawing

/// A path scaled by `k` about the centre (256, 256), as the page's inner layers are.
func scaled(_ path: CGPath, _ k: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: 256, y: 256).scaledBy(x: k, y: k).translatedBy(x: -256, y: -256)
    return path.copy(using: &t)!
}

/// An SVG radial gradient in bounding-box units (cx = cy = r = 0.5) over `box`, padded past its last stop.
func radial(_ ctx: CGContext, _ box: CGRect, _ stops: [(CGFloat, RGB)]) {
    let g = CGGradient(colorsSpace: space, colors: stops.map { cg($0.1) } as CFArray, locations: stops.map(\.0))!
    ctx.saveGState()
    ctx.translateBy(x: box.midX, y: box.midY)
    ctx.scaleBy(x: box.width / 2, y: box.height / 2)
    ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

let ci = CIContext()

/// Draws `path` filled with `color` at `alpha`, blurred like SVG's feGaussianBlur stdDeviation 14 (in design
/// points), through whatever clip `ctx` holds. `design` maps the 512 design space to the bitmap's pixels.
func blurred(_ ctx: CGContext, _ path: CGPath, _ color: RGB, _ alpha: CGFloat, pixels: Int, design: CGAffineTransform) {
    let layer = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.concatenate(design)
    layer.addPath(path)
    layer.setFillColor(cg(color, alpha))
    layer.fillPath()
    let source = CIImage(cgImage: layer.makeImage()!)
    let sigma = 14 * CGFloat(pixels) / 512
    let blur = source.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: source.extent)
    let image = ci.createCGImage(blur, from: source.extent)!
    ctx.saveGState()
    ctx.concatenate(design.inverted())
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.restoreGState()
}

/// Draws the icon at `pixels` × `pixels`; without `tile`, everything but the tile's gradient, transparent behind it
/// (the eye the app draws over each Dock step: Phase 6 Step 9).
func draw(pixels: Int, tile drawTile: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 512
    // Design space has y down (as the page's SVG); flip once.
    let design = CGAffineTransform(translationX: 0, y: CGFloat(pixels)).scaledBy(x: s, y: -s)
    ctx.concatenate(design)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The tile: a rounded square, the tile colour lightened 8 % at the top to darkened 55 % at the bottom.
    ctx.saveGState()
    ctx.addPath(square); ctx.clip()
    if drawTile {
        let bg = CGGradient(colorsSpace: space, colors: [cg(mix(tile, white, 0.08)), cg(darken(tile, 0.55))] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 26), end: CGPoint(x: 0, y: 486), options: [])
    }

    // The flames, clipped to the tile: a blurred glow, the fire gradient, a lighter inner layer.
    blurred(ctx, flame, glow, 0.55, pixels: pixels, design: design)
    ctx.saveGState()
    ctx.addPath(flame); ctx.clip()
    radial(ctx, flame.boundingBoxOfPath,
           [(0.3, flameInner), (0.62, mix(flameInner, flameOuter, 0.55)), (1, flameOuter)])
    ctx.restoreGState()
    ctx.addPath(scaled(flame, 0.86))
    ctx.setFillColor(cg(mix(flameInner, white, 0.45), 0.5))
    ctx.fillPath()
    ctx.restoreGState()

    // Inside the eye: the iris, the pupil's fire fringe (glow, fill, lighter layer), the slit.
    ctx.saveGState()
    ctx.addPath(eye); ctx.clip()
    radial(ctx, CGRect(x: 48, y: 120, width: 416, height: 272),
           [(0, irisCentre), (0.35, mix(irisCentre, irisRim, 0.35)), (0.75, mix(irisCentre, irisRim, 0.72)), (1, irisRim)])
    blurred(ctx, pupilFlame, pupilFire, 0.6, pixels: pixels, design: design)
    ctx.addPath(pupilFlame); ctx.setFillColor(cg(pupilFire)); ctx.fillPath()
    ctx.addPath(scaled(pupilFlame, 0.93)); ctx.setFillColor(cg(mix(pupilFire, white, 0.45), 0.5)); ctx.fillPath()
    ctx.addPath(pupilSlit); ctx.setFillColor(cg(pupil)); ctx.fillPath()
    ctx.restoreGState()

    // The lid line.
    ctx.addPath(eye)
    ctx.setStrokeColor(cg(rim)); ctx.setLineWidth(6); ctx.setLineJoin(.round)
    ctx.strokePath()
    return ctx.makeImage()!
}

/// AppKit adds EXIF even to a fresh bitmap. Keep rendering chunks (including colour and DPI), not metadata.
func pngWithoutMetadata(_ rep: NSBitmapImageRep) -> Data {
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
    let renderingChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "pHYs"]
    var result = Data(png.prefix(8))
    var offset = 8
    while offset < png.count {
        guard png.count - offset >= 12 else { fatalError("truncated PNG chunk") }
        let length = png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= png.count - offset - 12 else { fatalError("truncated PNG data") }
        let end = offset + length + 12
        let kind = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
        if renderingChunks.contains(kind) { result.append(png[offset..<end]) }
        offset = end
    }
    return result
}

try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = NSBitmapImageRep(cgImage: draw(pixels: points * scale))
        rep.size = NSSize(width: points, height: points)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try pngWithoutMetadata(rep).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
// The eye without its tile, beside the iconset, at the iconset's largest size: the app draws it over each Dock step.
let eyeURL = URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("AppIcon-eye.png")
let eyeRep = NSBitmapImageRep(cgImage: draw(pixels: 1024, tile: false))
eyeRep.size = NSSize(width: 512, height: 512)
try pngWithoutMetadata(eyeRep).write(to: eyeURL)
print("wrote 10 PNGs to \(out) and the eye to \(eyeURL.path)")
