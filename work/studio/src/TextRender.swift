import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RenderSpec: Decodable {
    let width: Int
    let height: Int
    let text: String
    let fontFamily: String
    let fontSize: Double
    let textColorHex: String
    let strokeColorHex: String
    let strokeWidth: Double
    let shadowEnabled: Bool
    let backgroundEnabled: Bool
    let backgroundColorHex: String
    let backgroundOpacity: Double
    let posX: Double
    let posY: Double

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case text
        case fontFamily
        case fontSize
        case textColorHex
        case strokeColorHex
        case strokeWidth
        case shadowEnabled
        case backgroundEnabled
        case backgroundColorHex
        case backgroundOpacity
        case posX
        case posY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "PingFang TC"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48.0
        textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#000000"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 3.0
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        backgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        backgroundColorHex = try c.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#000000"
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.55
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? 0.5
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? 0.86
    }
}

private func writeStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func clamp(_ value: Double, min minVal: Double, max maxVal: Double) -> Double {
    if !value.isFinite {
        return minVal
    }
    return Swift.min(Swift.max(value, minVal), maxVal)
}

private func parseHexColor(_ hex: String, fallback: NSColor) -> NSColor {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("#") {
        cleaned.removeFirst()
    }
    if cleaned.count == 3 {
        cleaned = cleaned.map { "\($0)\($0)" }.joined()
    } else if cleaned.count == 4 {
        cleaned = cleaned.map { "\($0)\($0)" }.joined()
    }
    guard cleaned.count == 6 || cleaned.count == 8,
          let value = UInt64(cleaned, radix: 16) else {
        return fallback
    }
    if cleaned.count == 6 {
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    } else {
        let r = CGFloat((value >> 24) & 0xFF) / 255.0
        let g = CGFloat((value >> 16) & 0xFF) / 255.0
        let b = CGFloat((value >> 8) & 0xFF) / 255.0
        let a = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

private func resolveFont(family rawFamily: String, size: CGFloat) -> NSFont {
    let family = rawFamily.trimmingCharacters(in: .whitespacesAndNewlines)
    let fm = NSFontManager.shared

    if !family.isEmpty {
        // Prefer crisp Semibold/Medium weights when PingFang TC is requested.
        if family.caseInsensitiveCompare("PingFang TC") == .orderedSame {
            for candidate in ["PingFangTC-Semibold", "PingFangTC-Medium"] {
                if let font = NSFont(name: candidate, size: size) {
                    return font
                }
            }
        }
        // Direct PostScript name match (e.g. "PingFangTC-Semibold", "NotoSansTC-Bold").
        if let direct = NSFont(name: family, size: size) {
            return direct
        }
        // Family lookup preferring bold/semibold/medium weights.
        if let boldMatch = fm.font(withFamily: family, traits: .boldFontMask, weight: 8, size: size) {
            return boldMatch
        }
        if let mediumMatch = fm.font(withFamily: family, traits: [], weight: 6, size: size) {
            return mediumMatch
        }
        if let regularMatch = fm.font(withFamily: family, traits: [], weight: 5, size: size) {
            return regularMatch
        }
        // Case-insensitive family name scan.
        if let matchedFamily = fm.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
            if let font = fm.font(withFamily: matchedFamily, traits: .boldFontMask, weight: 8, size: size)
                ?? fm.font(withFamily: matchedFamily, traits: [], weight: 6, size: size)
                ?? fm.font(withFamily: matchedFamily, traits: [], weight: 5, size: size) {
                return font
            }
        }
    }

    // Explicit Traditional Chinese fallback chain to guarantee no tofu boxes.
    for psName in ["PingFangTC-Semibold", "PingFangTC-Medium"] {
        if let font = NSFont(name: psName, size: size) {
            return font
        }
    }
    if let pingFang = fm.font(withFamily: "PingFang TC", traits: [], weight: 6, size: size)
        ?? fm.font(withFamily: "PingFang TC", traits: [], weight: 5, size: size) {
        return pingFang
    }
    if let heiti = NSFont(name: "STHeitiTC-Medium", size: size) {
        return heiti
    }
    return NSFont.boldSystemFont(ofSize: size)
}

private func makeLayout(
    text: String,
    attributes: [NSAttributedString.Key: Any],
    maxWidth: CGFloat
) -> (NSTextStorage, NSLayoutManager, NSTextContainer, NSRect) {
    let textStorage = NSTextStorage(string: text, attributes: attributes)
    let layoutManager = NSLayoutManager()
    layoutManager.usesFontLeading = true
    let textContainer = NSTextContainer(size: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = .byWordWrapping
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    layoutManager.ensureLayout(for: textContainer)
    let glyphRange = layoutManager.glyphRange(for: textContainer)

    var unionRect = NSRect.null
    if glyphRange.length > 0 {
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            unionRect = unionRect.isNull ? usedRect : unionRect.union(usedRect)
        }
    }
    if unionRect.isNull {
        unionRect = layoutManager.usedRect(for: textContainer)
    }
    return (textStorage, layoutManager, textContainer, unionRect)
}

private func renderTextImage(spec: RenderSpec) throws -> CGImage {
    guard spec.width >= 16, spec.width <= 16384, spec.height >= 16, spec.height <= 16384 else {
        throw NSError(
            domain: "TextRender",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid canvas size: \(spec.width)x\(spec.height)"]
        )
    }

    let width = spec.width
    let height = spec.height
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        throw NSError(
            domain: "TextRender",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate RGBA CGContext"]
        )
    }

    // Clear entire canvas to fully transparent RGBA.
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(true)
    ctx.setShouldSmoothFonts(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSubpixelPositionFonts(true)

    let trimmed = spec.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        guard let emptyImage = ctx.makeImage() else {
            throw NSError(domain: "TextRender", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to snapshot empty CGImage"])
        }
        return emptyImage
    }

    // Scale everything proportionally against a 1080p baseline.
    let scale = Double(height) / 1080.0
    let baseFontSize = clamp(spec.fontSize, min: 8.0, max: 400.0)
    let baseStrokeWidth = clamp(spec.strokeWidth, min: 0.0, max: 40.0)

    let scaledFontSize = CGFloat(max(6.0, baseFontSize * scale))
    let scaledStrokeWidth = CGFloat(max(0.0, baseStrokeWidth * scale))
    let bgPadX = CGFloat(max(4.0, (baseFontSize * 0.45) * scale))
    let bgPadY = CGFloat(max(3.0, (baseFontSize * 0.24) * scale))
    let cornerRadius = CGFloat(max(2.0, 14.0 * scale))

    let font = resolveFont(family: spec.fontFamily, size: scaledFontSize)
    let textColor = parseHexColor(spec.textColorHex, fallback: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    let strokeColor = parseHexColor(spec.strokeColorHex, fallback: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    let bgColor = parseHexColor(spec.backgroundColorHex, fallback: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    let bgOpacity = CGFloat(clamp(spec.backgroundOpacity, min: 0.0, max: 1.0))

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.lineSpacing = scaledFontSize * 0.16

    // Normalize line endings to \n while preserving intentional multi-line breaks.
    let normalizedText = spec.text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    let maxTextWidth = max(16.0, CGFloat(width) * 0.88)

    let fillAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraphStyle,
    ]

    let (fillStorage, fillLayout, fillContainer, tightRect) = makeLayout(
        text: normalizedText,
        attributes: fillAttributes,
        maxWidth: maxTextWidth
    )
    let fillGlyphRange = fillLayout.glyphRange(for: fillContainer)

    let textW = ceil(tightRect.width)
    let textH = ceil(tightRect.height)
    let strokeMargin = scaledStrokeWidth

    let boxW: CGFloat
    let boxH: CGFloat
    if spec.backgroundEnabled {
        boxW = textW + 2.0 * (bgPadX + strokeMargin)
        boxH = textH + 2.0 * (bgPadY + strokeMargin)
    } else {
        boxW = textW + 2.0 * strokeMargin
        boxH = textH + 2.0 * strokeMargin
    }

    let clampedPosX = CGFloat(clamp(spec.posX, min: 0.0, max: 1.0))
    let clampedPosY = CGFloat(clamp(spec.posY, min: 0.0, max: 1.0))
    let targetCenterX = clampedPosX * CGFloat(width)
    let targetCenterY = clampedPosY * CGFloat(height)

    let marginX = min(CGFloat(width) * 0.02, CGFloat(max(2.0, 8.0 * scale)))
    let marginY = min(CGFloat(height) * 0.02, CGFloat(max(2.0, 8.0 * scale)))

    let maxBoxX = max(marginX, CGFloat(width) - boxW - marginX)
    let maxBoxY = max(marginY, CGFloat(height) - boxH - marginY)
    let boxX = min(max(targetCenterX - boxW / 2.0, marginX), maxBoxX)
    let boxY = min(max(targetCenterY - boxH / 2.0, marginY), maxBoxY)
    let boxRect = CGRect(x: boxX, y: boxY, width: min(boxW, CGFloat(width) - 2.0 * marginX), height: min(boxH, CGFloat(height) - 2.0 * marginY))

    let textOriginX = boxRect.minX + (boxRect.width - textW) / 2.0 - tightRect.minX
    let textOriginY = boxRect.minY + (boxRect.height - textH) / 2.0 - tightRect.minY
    let drawPoint = NSPoint(x: textOriginX, y: textOriginY)

    // Flip context so (0, 0) is top-left and posY=0 is top, posY=0.86 is bottom subtitle area.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    // 1. Optional rounded semi-transparent background plate.
    if spec.backgroundEnabled && bgOpacity > 0.001 {
        let clampedRadius = min(cornerRadius, min(boxRect.width, boxRect.height) / 2.0)
        let bgPath = CGPath(roundedRect: boxRect, cornerWidth: clampedRadius, cornerHeight: clampedRadius, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(bgColor.withAlphaComponent(bgOpacity).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    let shadowOffset = CGSize(width: 0, height: CGFloat(-max(1.0, 2.5 * scale)))
    let shadowBlur = CGFloat(max(1.0, 6.0 * scale))
    let shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75)

    // 2. Two-pass text rendering: outer stroke (with optional shadow) first, then crisp fill on top.
    if scaledStrokeWidth > 0.01 {
        // Positive strokeWidth percentage draws stroke only; doubling width ensures the outer half
        // equals scaledStrokeWidth while Pass 2 cleanly covers the inner half without eating strokes.
        let strokePercent = Double((2.0 * scaledStrokeWidth / scaledFontSize) * 100.0)
        let strokeAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: strokeColor,
            .strokeColor: strokeColor,
            .strokeWidth: strokePercent,
            .paragraphStyle: paragraphStyle,
        ]
        let (strokeStorage, strokeLayout, strokeContainer, _) = makeLayout(
            text: normalizedText,
            attributes: strokeAttributes,
            maxWidth: maxTextWidth
        )
        let strokeGlyphRange = strokeLayout.glyphRange(for: strokeContainer)

        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setMiterLimit(2.0)
        if spec.shadowEnabled {
            ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
        }
        withExtendedLifetime(strokeStorage) {
            strokeLayout.drawGlyphs(forGlyphRange: strokeGlyphRange, at: drawPoint)
        }
        ctx.restoreGState()
    }

    // 3. Foreground text fill (carries shadow only when stroke is disabled).
    ctx.saveGState()
    if spec.shadowEnabled && scaledStrokeWidth <= 0.01 {
        ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
    }
    withExtendedLifetime(fillStorage) {
        fillLayout.drawGlyphs(forGlyphRange: fillGlyphRange, at: drawPoint)
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "TextRender", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
    }
    return image
}

struct ShapeSpec: Decodable {
    let width: Int
    let height: Int
    let kind: String
    let posX: Double
    let posY: Double
    let shapeWidth: Double
    let shapeHeight: Double
    let rotation: Double
    let opacity: Double
    let fillColorHex: String
    let fillGradientEnabled: Bool
    let fillGradientEndHex: String
    let fillGradientAngle: Double
    let strokeColorHex: String
    let strokeWidth: Double
    let cornerRadius: Double
    let shadowEnabled: Bool
    let label: String
    let labelColorHex: String
    let labelFontSize: Double
    let labelFontFamily: String

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case kind
        case posX
        case posY
        case shapeWidth
        case shapeHeight
        case rotation
        case opacity
        case fillColorHex
        case fillGradientEnabled
        case fillGradientEndHex
        case fillGradientAngle
        case strokeColorHex
        case strokeWidth
        case cornerRadius
        case shadowEnabled
        case label
        case labelColorHex
        case labelFontSize
        case labelFontFamily
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        kind = (try c.decodeIfPresent(String.self, forKey: .kind) ?? "rounded_rect")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        posX = try c.decodeIfPresent(Double.self, forKey: .posX) ?? 0.5
        posY = try c.decodeIfPresent(Double.self, forKey: .posY) ?? 0.5
        shapeWidth = try c.decodeIfPresent(Double.self, forKey: .shapeWidth) ?? 0.32
        shapeHeight = try c.decodeIfPresent(Double.self, forKey: .shapeHeight) ?? 0.18
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0.0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        fillColorHex = try c.decodeIfPresent(String.self, forKey: .fillColorHex) ?? "#2563EB"
        fillGradientEnabled = try c.decodeIfPresent(Bool.self, forKey: .fillGradientEnabled) ?? false
        fillGradientEndHex = try c.decodeIfPresent(String.self, forKey: .fillGradientEndHex) ?? "#7C3AED"
        fillGradientAngle = try c.decodeIfPresent(Double.self, forKey: .fillGradientAngle) ?? 45.0
        strokeColorHex = try c.decodeIfPresent(String.self, forKey: .strokeColorHex) ?? "#FFFFFF"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 3.0
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0.2
        shadowEnabled = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        labelColorHex = try c.decodeIfPresent(String.self, forKey: .labelColorHex) ?? "#FFFFFF"
        labelFontSize = try c.decodeIfPresent(Double.self, forKey: .labelFontSize) ?? 36.0
        labelFontFamily = try c.decodeIfPresent(String.self, forKey: .labelFontFamily) ?? "PingFang TC"
    }
}

private func buildShapePath(kind: String, rect: CGRect, cornerRadiusRatio: CGFloat, lineThickness: CGFloat) -> CGPath {
    let w = rect.width
    let h = rect.height
    let minDim = min(w, h)

    switch kind {
    case "rect":
        return CGPath(rect: rect, transform: nil)

    case "rounded_rect":
        let r = min(max(0.0, cornerRadiusRatio) * (minDim * 0.5), minDim * 0.5)
        if r <= 0.5 {
            return CGPath(rect: rect, transform: nil)
        }
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

    case "pill":
        let r = minDim * 0.5
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

    case "ellipse", "circle":
        return CGPath(ellipseIn: rect, transform: nil)

    case "triangle":
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path

    case "star":
        let path = CGMutablePath()
        let cx = rect.midX
        let cy = rect.midY
        let rxOuter = w * 0.5
        let ryOuter = h * 0.5
        let innerRatio: CGFloat = 0.42
        let points = 5
        for i in 0..<(points * 2) {
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) * (CGFloat.pi / CGFloat(points))
            let ratio: CGFloat = (i % 2 == 0) ? 1.0 : innerRatio
            let px = cx + cos(angle) * rxOuter * ratio
            let py = cy + sin(angle) * ryOuter * ratio
            if i == 0 {
                path.move(to: CGPoint(x: px, y: py))
            } else {
                path.addLine(to: CGPoint(x: px, y: py))
            }
        }
        path.closeSubpath()
        return path

    case "arrow":
        let path = CGMutablePath()
        let shaftHalfH = h * 0.21
        let headX = rect.minX + w * 0.58
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - shaftHalfH))
        path.addLine(to: CGPoint(x: headX, y: rect.midY - shaftHalfH))
        path.addLine(to: CGPoint(x: headX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: headX, y: rect.maxY))
        path.addLine(to: CGPoint(x: headX, y: rect.midY + shaftHalfH))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + shaftHalfH))
        path.closeSubpath()
        return path

    case "line":
        let thickness = max(2.0, min(h, lineThickness))
        let lineRect = CGRect(x: rect.minX, y: rect.midY - thickness * 0.5, width: w, height: thickness)
        let r = min(thickness * 0.5, w * 0.5)
        return CGPath(roundedRect: lineRect, cornerWidth: r, cornerHeight: r, transform: nil)

    default:
        let r = min(max(0.0, cornerRadiusRatio) * (minDim * 0.5), minDim * 0.5)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

private func renderShapeImage(spec: ShapeSpec) throws -> CGImage {
    guard spec.width >= 16, spec.width <= 16384, spec.height >= 16, spec.height <= 16384 else {
        throw NSError(
            domain: "TextRender",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "Invalid canvas size: \(spec.width)x\(spec.height)"]
        )
    }

    let width = spec.width
    let height = spec.height
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        throw NSError(
            domain: "TextRender",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate RGBA CGContext for shape"]
        )
    }

    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(true)
    ctx.setShouldSmoothFonts(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSubpixelPositionFonts(true)

    let opacity = CGFloat(clamp(spec.opacity, min: 0.0, max: 1.0))
    if opacity <= 0.001 {
        guard let emptyImg = ctx.makeImage() else {
            throw NSError(domain: "TextRender", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to create empty shape image"])
        }
        return emptyImg
    }

    let scale = Double(height) / 1080.0
    let clampedPosX = CGFloat(clamp(spec.posX, min: 0.0, max: 1.0))
    let clampedPosY = CGFloat(clamp(spec.posY, min: 0.0, max: 1.0))
    let shapeW = max(4.0, CGFloat(clamp(spec.shapeWidth, min: 0.01, max: 1.0)) * CGFloat(width))
    let shapeH = max(4.0, CGFloat(clamp(spec.shapeHeight, min: 0.01, max: 1.0)) * CGFloat(height))
    let centerX = clampedPosX * CGFloat(width)
    let centerY = clampedPosY * CGFloat(height)
    let rotationRad = CGFloat(spec.rotation * Double.pi / 180.0)
    let scaledStrokeWidth = CGFloat(max(0.0, clamp(spec.strokeWidth, min: 0.0, max: 80.0) * scale))
    let cornerRatio = CGFloat(clamp(spec.cornerRadius, min: 0.0, max: 1.0))
    let lineThickness = max(scaledStrokeWidth, CGFloat(max(4.0, 10.0 * scale)))

    let fillColor = parseHexColor(spec.fillColorHex, fallback: NSColor(srgbRed: 0.15, green: 0.39, blue: 0.92, alpha: 1.0))
    let fillEndColor = parseHexColor(spec.fillGradientEndHex, fallback: NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1.0))
    let strokeColor = parseHexColor(spec.strokeColorHex, fallback: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    let labelColor = parseHexColor(spec.labelColorHex, fallback: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))

    let localRect = CGRect(x: -shapeW * 0.5, y: -shapeH * 0.5, width: shapeW, height: shapeH)
    let shapePath = buildShapePath(
        kind: spec.kind,
        rect: localRect,
        cornerRadiusRatio: cornerRatio,
        lineThickness: lineThickness
    )

    // Flip context so (0, 0) is top-left, matching RenderSpec coordinates.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    // Uniform opacity layer for fill + stroke + shadow + label.
    ctx.setAlpha(opacity)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.saveGState()
    ctx.translateBy(x: centerX, y: centerY)
    if abs(rotationRad) > 1e-6 {
        ctx.rotate(by: rotationRad)
    }

    let shadowOffset = CGSize(width: 0, height: CGFloat(-max(2.0, 6.0 * scale)))
    let shadowBlur = CGFloat(max(2.0, 14.0 * scale))
    let shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.50)

    // 1. Optional drop shadow cast by the shape silhouette.
    if spec.shadowEnabled {
        ctx.saveGState()
        ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColor)
        ctx.setFillColor(fillColor.cgColor)
        ctx.addPath(shapePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Fill (solid or angled linear gradient).
    ctx.saveGState()
    ctx.addPath(shapePath)
    if spec.fillGradientEnabled {
        ctx.clip()
        let gradAngle = CGFloat(spec.fillGradientAngle * Double.pi / 180.0)
        let dx = cos(gradAngle)
        let dy = sin(gradAngle)
        let halfDiag = hypot(shapeW, shapeH) * 0.5
        let startPt = CGPoint(x: -dx * halfDiag, y: -dy * halfDiag)
        let endPt = CGPoint(x: dx * halfDiag, y: dy * halfDiag)
        let colors = [fillColor.cgColor, fillEndColor.cgColor] as CFArray
        let locations: [CGFloat] = [0.0, 1.0]
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: startPt,
                end: endPt,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            ctx.setFillColor(fillColor.cgColor)
            ctx.fill(localRect)
        }
    } else {
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 3. Optional crisp stroke (skip double stroke for decorative line unless contrasting color).
    if scaledStrokeWidth > 0.25 && spec.kind != "line" {
        ctx.saveGState()
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(scaledStrokeWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(shapePath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. Optional centered label inside the shape.
    let trimmedLabel = spec.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLabel.isEmpty {
        let baseLabelFontSize = clamp(spec.labelFontSize, min: 8.0, max: 300.0)
        let scaledLabelFontSize = CGFloat(max(6.0, baseLabelFontSize * scale))
        let font = resolveFont(family: spec.labelFontFamily, size: scaledLabelFontSize)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = scaledLabelFontSize * 0.12

        let normalizedLabel = spec.label
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let maxLabelWidth = max(16.0, shapeW * 0.86)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let (storage, layout, container, tightRect) = makeLayout(
            text: normalizedLabel,
            attributes: attrs,
            maxWidth: maxLabelWidth
        )
        let glyphRange = layout.glyphRange(for: container)
        let textOriginX = -tightRect.width * 0.5 - tightRect.minX
        let textOriginY = -tightRect.height * 0.5 - tightRect.minY
        let drawPoint = NSPoint(x: textOriginX, y: textOriginY)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.saveGState()
        if spec.shadowEnabled {
            ctx.setShadow(
                offset: CGSize(width: 0, height: CGFloat(-max(1.0, 2.0 * scale))),
                blur: CGFloat(max(1.0, 4.0 * scale)),
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65)
            )
        }
        withExtendedLifetime(storage) {
            layout.drawGlyphs(forGlyphRange: glyphRange, at: drawPoint)
        }
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "TextRender", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed to create shape CGImage"])
    }
    return image
}

private func writePNG(_ image: CGImage, to outputURL: URL) throws {
    let parent = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(
            domain: "TextRender",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG image destination: \(outputURL.path)"]
        )
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "TextRender",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG file: \(outputURL.path)"]
        )
    }
}

private func runMain() -> Int32 {
    let args = CommandLine.arguments

    if args.count == 4 && args[1] == "--shape" {
        let specURL = URL(fileURLWithPath: args[2])
        let outputURL = URL(fileURLWithPath: args[3])
        do {
            let data = try Data(contentsOf: specURL)
            let spec = try JSONDecoder().decode(ShapeSpec.self, from: data)
            let image = try renderShapeImage(spec: spec)
            try writePNG(image, to: outputURL)
            return 0
        } catch {
            writeStderr("textrender --shape error: \(error.localizedDescription)")
            return 1
        }
    }

    guard args.count == 3 else {
        writeStderr("Usage: textrender <spec.json> <output.png> | textrender --shape <spec.json> <output.png>")
        return 1
    }

    let specURL = URL(fileURLWithPath: args[1])
    let outputURL = URL(fileURLWithPath: args[2])

    do {
        let data = try Data(contentsOf: specURL)
        let spec = try JSONDecoder().decode(RenderSpec.self, from: data)
        let image = try renderTextImage(spec: spec)
        try writePNG(image, to: outputURL)
        return 0
    } catch {
        writeStderr("textrender error: \(error.localizedDescription)")
        return 1
    }
}

exit(runMain())
