#!/usr/bin/env swift
//
// make-icon.swift — dessine l'icône de Hublot.
//
// Un cerclage de laiton sur le noir, et la lueur du four en dessous : la même
// idée que `AmbientBackground`, réduite à 1024 points. Générée plutôt que
// dessinée à la main pour que les couleurs restent celles du thème.
//
//   swift Tools/make-icon.swift IAClient-UI/Assets.xcassets/AppIcon.appiconset/icon.png
//
import AppKit
import CoreGraphics
import Foundation

let side = 1024.0
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

// Les jetons de `HublotTheme.swift`, recopiés ici parce qu'un script autonome
// ne peut pas importer le module de l'app.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let abyss = rgb(0x07_080A)
let ember = rgb(0xE8_A33D)
let forge = rgb(0x4A_2E0C)

guard
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else { fatalError("contexte graphique impossible") }

// Le fond, puis la lueur qui monte du bas — comme dans l'app.
context.setFillColor(abyss)
context.fill(CGRect(x: 0, y: 0, width: side, height: side))

if let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [forge, abyss] as CFArray,
    locations: [0, 1]
) {
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: side / 2, y: side * 0.12), startRadius: 0,
        endCenter: CGPoint(x: side / 2, y: side * 0.12), endRadius: side * 0.72,
        options: []
    )
}

// Le cerclage. Épais, centré, avec un halo : c'est le seul objet de l'icône.
let ringRadius = side * 0.30
let ringWidth = side * 0.055
let center = CGPoint(x: side / 2, y: side / 2)

context.saveGState()
context.setShadow(offset: .zero, blur: side * 0.09, color: ember.copy(alpha: 0.75))
context.setStrokeColor(ember)
context.setLineWidth(ringWidth)
context.strokeEllipse(
    in: CGRect(
        x: center.x - ringRadius, y: center.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2
    )
)
context.restoreGState()

// Un reflet en haut à gauche : sans lui, le cercle est un trait, pas du verre.
context.saveGState()
context.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
context.setLineWidth(ringWidth * 0.28)
context.setLineCap(.round)
context.addArc(
    center: center, radius: ringRadius,
    startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false
)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("rendu impossible") }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("encodage PNG impossible")
}
try data.write(to: URL(fileURLWithPath: output))
print("▸ \(output)")
