#!/usr/bin/env swift
// Render the SF Symbol `wand.and.stars` on a rounded indigo background
// at every size macOS's `iconutil` expects, then pipe the resulting
// .iconset folder through iconutil to produce assets/Wand.icns.
//
// Run from the repo root:
//   swift packaging/icon/generate-wand-icon.swift
//
// The script writes assets/Wand.iconset/* then calls `iconutil -c icns`.
// Re-run any time the icon should change (try a different symbol, tint,
// or corner radius). Commits should include only the resulting .icns,
// not the intermediate iconset directory.

import AppKit
import Foundation

let symbolName = "wand.and.stars"
// Indigo / violet — magical wand vibe without going too "kids' toy".
let background = NSColor(srgbRed: 0.36, green: 0.22, blue: 0.78, alpha: 1.0)
let foreground = NSColor.white
let outputDir = "assets/Wand.iconset"

let fm = FileManager.default
if fm.fileExists(atPath: outputDir) {
    try? fm.removeItem(atPath: outputDir)
}
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Apple's iconutil naming matrix — each PNG must be present at these
// exact filenames for the .icns to be complete.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let canvas = NSImage(size: NSSize(width: px, height: px))
    canvas.lockFocus()

    // Background: rounded square. macOS Big Sur convention is ~22.5%
    // of the side length for the corner radius.
    let cornerRadius = CGFloat(px) * 0.225
    let bgRect = NSRect(x: 0, y: 0, width: px, height: px)
    background.setFill()
    NSBezierPath(roundedRect: bgRect,
                 xRadius: cornerRadius,
                 yRadius: cornerRadius).fill()

    // Foreground: SF Symbol rendered ~65% of icon side. Larger and
    // it hugs the edges; smaller and it looks lost in the canvas.
    let symbolPointSize = CGFloat(px) * 0.65
    let baseConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize,
                                                  weight: .regular)
    let config: NSImage.SymbolConfiguration
    if #available(macOS 13.0, *) {
        config = baseConfig.applying(.preferringMonochrome())
    } else {
        config = baseConfig
    }
    guard let symbol = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        canvas.unlockFocus()
        FileHandle.standardError.write(Data(
            "warn: couldn't render symbol \(symbolName) at \(px)px\n".utf8))
        continue
    }

    // Tint to white by drawing the symbol, then filling with the
    // foreground colour using sourceAtop (paints only where the
    // symbol's alpha is non-zero).
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        foreground.set()
        rect.fill(using: .sourceAtop)
        return true
    }

    let symSize = tinted.size
    let origin = NSPoint(
        x: (CGFloat(px) - symSize.width) / 2,
        y: (CGFloat(px) - symSize.height) / 2
    )
    tinted.draw(in: NSRect(origin: origin, size: symSize))

    canvas.unlockFocus()

    guard let cg = canvas.cgImage(forProposedRect: nil,
                                   context: nil, hints: nil) else {
        FileHandle.standardError.write(Data("warn: no cg for \(name)\n".utf8))
        continue
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("warn: no png for \(name)\n".utf8))
        continue
    }
    try png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
    print("wrote \(name) (\(png.count) bytes)")
}

// Pipe through iconutil to bundle the iconset into a single .icns.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", outputDir, "-o", "assets/Wand.icns"]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data(
        "iconutil failed: exit \(task.terminationStatus)\n".utf8))
    exit(1)
}

// Clean up the intermediate iconset — only the .icns is checked in.
try? fm.removeItem(atPath: outputDir)
print("wrote assets/Wand.icns")
