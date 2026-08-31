#!/usr/bin/env swift
// Draws Lupp.iconset with CoreGraphics — no asset catalog, so no Xcode needed.
//
// House style, measured off the existing icon set rather than guessed: flat fill
// (no gradient), full-bleed circular plate, one single-colour mark at roughly
// 0.55 of the plate diameter and ~16% of it in ink, dark-neutral plate.

import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Lupp.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let plate = CGColor(red: 0.113, green: 0.113, blue: 0.125, alpha: 1)   // #1D1D20
let mark  = CGColor(red: 0.910, green: 0.894, blue: 0.855, alpha: 1)   // warm off-white

func drawIcon(size D: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(D), height: Int(D),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Full-bleed plate: the circle is the icon's silhouette, corners stay clear.
    ctx.setFillColor(plate)
    ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: D, height: D))

    // Loupe: ring plus a short barrel, offset so the composite mark reads centred.
    let cx = D * 0.455, cy = D * 0.545
    let r = D * 0.225
    let lw = D * 0.075
    ctx.setStrokeColor(mark)
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

    let a = -CGFloat.pi / 4
    let start = CGPoint(x: cx + cos(a) * (r + lw * 0.15), y: cy + sin(a) * (r + lw * 0.15))
    let end   = CGPoint(x: cx + cos(a) * (r + D * 0.185), y: cy + sin(a) * (r + D * 0.185))
    ctx.move(to: start)
    ctx.addLine(to: end)
    ctx.strokePath()

    return ctx.makeImage()
}

// The set .icns wants: each logical size at 1x and 2x.
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
