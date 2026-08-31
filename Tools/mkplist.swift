#!/usr/bin/env swift
// Writes Contents/Info.plist.
//
// The document types are read from ImageIO at build time rather than hand-listed,
// so the "Open With" claim is exactly the set the running code can actually
// decode — no format advertised that then fails to open.

import Foundation
import ImageIO

let version = ProcessInfo.processInfo.environment["LUPP_VERSION"] ?? "0.1.0"
let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Info.plist")

let types = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).sorted()

let plist: [String: Any] = [
    "CFBundleName": "Lupp",
    "CFBundleDisplayName": "Lupp",
    "CFBundleIdentifier": "xyz.nodegroup.lupp",
    "CFBundleExecutable": "Lupp",
    "CFBundleIconFile": "Lupp",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": true,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "MIT licensed.",
    // Alternate, not Default: being listed under "Open With" is the app's job;
    // actually taking over a file type stays the user's explicit choice.
    "CFBundleDocumentTypes": [
        [
            "CFBundleTypeName": "Image",
            "CFBundleTypeRole": "Viewer",
            "CFBundleTypeIconFile": "Lupp",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": types,
        ],
        [
            "CFBundleTypeName": "Lupp Session",
            "CFBundleTypeRole": "Editor",
            "CFBundleTypeIconFile": "Lupp",
            // Owner, not Alternate: nothing else made these, so double-clicking
            // one should come here.
            "LSHandlerRank": "Owner",
            "LSItemContentTypes": ["xyz.nodegroup.lupp.session"],
        ],
    ],
    "UTExportedTypeDeclarations": [[
        "UTTypeIdentifier": "xyz.nodegroup.lupp.session",
        "UTTypeDescription": "Lupp Session",
        "UTTypeConformsTo": ["public.json", "public.data"],
        "UTTypeTagSpecification": ["public.filename-extension": ["luppsession"]],
    ]],
]

let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
try data.write(to: out)
print("Info.plist: \(types.count) document types, version \(version)")
