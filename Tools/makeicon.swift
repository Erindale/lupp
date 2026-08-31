#!/usr/bin/env swift
// Draws Lupp.iconset with CoreGraphics — no asset catalog, so no Xcode needed.
//
// A four-corner mesh gradient on a softly distorted circle, corners transparent.
// Rendered per-pixel rather than with CGGradient because a four-point blend isn't
// a linear or radial gradient, and because the shape's radius varies with angle.
//
// The blend runs in Oklab. Interpolating four saturated hues in sRGB drags the
// middle toward grey — Oklab is perceptually uniform, so the centre stays a real
// colour instead of mud.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Lupp.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Colour

struct RGB { var r, g, b: Double }
struct Lab { var l, a, b: Double }

func srgbToLinear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
func linearToSrgb(_ c: Double) -> Double {
    let v = min(max(c, 0), 1)
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
}

func hex(_ h: UInt32) -> RGB {
    RGB(r: srgbToLinear(Double((h >> 16) & 0xFF) / 255),
        g: srgbToLinear(Double((h >> 8) & 0xFF) / 255),
        b: srgbToLinear(Double(h & 0xFF) / 255))
}

func toOklab(_ c: RGB) -> Lab {
    let l = cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
    let m = cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
    let s = cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
    return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
               a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
               b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

func toRGB(_ c: Lab) -> RGB {
    let l = pow(c.l + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
    let m = pow(c.l - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
    let s = pow(c.l - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
    return RGB(r:  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
               g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
               b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
}

func mix(_ x: Lab, _ y: Lab, _ t: Double) -> Lab {
    Lab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
}

// MARK: - Design

let topLeft     = toOklab(hex(0x4B2ED8))   // violet
let topRight    = toOklab(hex(0x22C7E8))   // cyan
let bottomLeft  = toOklab(hex(0xE23A8E))   // rose
let bottomRight = toOklab(hex(0xFFAE3C))   // amber

/// Smoothstep on both axes so the mesh reads as a soft field rather than a
/// bilinear patch with visible directional banding through the middle.
func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

/// Radius as a function of angle — a circle with a slow wobble, small enough to
/// stay a circle at 16px and just enough to not look machine-drawn at 512.
func shapeRadius(_ theta: Double) -> Double {
    0.955 + 0.030 * sin(3 * theta + 0.7) + 0.017 * sin(2 * theta - 1.2)
}

func drawIcon(size D: Int) -> CGImage? {
    var px = [UInt8](repeating: 0, count: D * D * 4)
    let d = Double(D)
    let aa = 1.6 / d                                   // edge softness, ~1.6px

    for y in 0..<D {
        for x in 0..<D {
            let nx = (Double(x) + 0.5) / d * 2 - 1
            let ny = (Double(y) + 0.5) / d * 2 - 1
            let radius = (nx * nx + ny * ny).squareRoot()
            let edge = shapeRadius(atan2(-ny, nx))

            // 1 inside, 0 outside, smooth across the boundary.
            let alpha = min(max((edge - radius) / (2 * aa) + 0.5, 0), 1)
            if alpha <= 0 { continue }

            let u = smooth((nx + 1) / 2)
            let v = smooth((ny + 1) / 2)
            let lab = mix(mix(topLeft, topRight, u), mix(bottomLeft, bottomRight, u), v)
            let c = toRGB(lab)

            let o = (y * D + x) * 4
            px[o]     = UInt8(linearToSrgb(c.r) * 255 * alpha)
            px[o + 1] = UInt8(linearToSrgb(c.g) * 255 * alpha)
            px[o + 2] = UInt8(linearToSrgb(c.b) * 255 * alpha)
            px[o + 3] = UInt8(alpha * 255)
        }
    }

    guard let provider = CGDataProvider(data: Data(bytes: &px, count: px.count) as CFData)
    else { return nil }
    return CGImage(width: D, height: D, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: D * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}

let variants: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",    32),
    ("icon_32x32",      32),  ("icon_32x32@2x",    64),
    ("icon_128x128",   128),  ("icon_128x128@2x", 256),
    ("icon_256x256",   256),  ("icon_256x256@2x", 512),
    ("icon_512x512",   512),  ("icon_512x512@2x",1024),
]

for v in variants {
    guard let img = drawIcon(size: v.px) else {
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
