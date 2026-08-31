#!/usr/bin/env swift
// Draws Lupp.iconset with CoreGraphics — no asset catalog, so no Xcode needed.
//
// Full-bleed circular plate, as the rest of the Sidebar set is. The gradients are
// a deliberate departure from that set's flat fills: an image viewer's icon may
// as well be about colour.

import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Lupp.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], _ locations: [CGFloat],
                    from: CGPoint, to: CGPoint) {
    guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray,
                             locations: locations) else { return }
    ctx.drawLinearGradient(g, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawIcon(size D: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(D), height: Int(D),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The circle is the silhouette; corners stay transparent.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 0, y: 0, width: D, height: D))
    ctx.clip()

    // Plate: deep indigo through magenta into amber, along the diagonal.
    linearGradient(ctx,
                   [rgb(0x1B1145), rgb(0x6C2A96), rgb(0xD1417A), rgb(0xF9A03F)],
                   [0.04, 0.32, 0.60, 0.88],
                   from: CGPoint(x: 0, y: D), to: CGPoint(x: D, y: 0))

    // Offset disc: a cool gradient reading as a lens element over a warm field.
    let r = D * 0.262
    let cx = D * 0.665, cy = D * 0.655
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    ctx.clip()
    linearGradient(ctx,
                   [rgb(0x6FE7D2), rgb(0x35A8DE), rgb(0x2C57B8)],
                   [0, 0.5, 1],
                   from: CGPoint(x: cx - r, y: cy + r), to: CGPoint(x: cx + r, y: cy - r))
    ctx.restoreGState()

    // A soft highlight arc, to stop the disc reading as a flat sticker.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    ctx.clip()
    if let g = CGGradient(colorsSpace: space,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.34),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: cx - r * 0.6, y: cy + r),
                               end: CGPoint(x: cx, y: cy - r * 0.2), options: [])
    }
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()
}

let variants: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",    32),
    ("icon_32x32",      32),  ("icon_32x32@2x",    64),
    ("icon_128x128",   128),  ("icon_128x128@2x", 256),
    ("icon_256x256",   256),  ("icon_256x256@2x", 512),
    ("icon_512x512",   512),  ("icon_512x512@2x",1024),
]

for v in variants {
    guard let img = drawIcon(size: CGFloat(v.px)) else {
        FileHandle.standardError.write("failed to draw \(v.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outDir.appendingPathComponent("\(v.name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { exit(1) }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
print("wrote \(variants.count) sizes to \(outDir.path)")
