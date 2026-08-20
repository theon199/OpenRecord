import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CursorSpriteCapture {
    static func writeDefaultArrow(to directory: URL) throws -> CursorSprite {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(CaptureMediaFormat.defaultCursorSpriteID).png"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)

        if let sprite = try? writeSystemArrow(to: url, fileName: fileName) {
            return sprite
        }
        return try writeDrawnArrow(to: url, fileName: fileName)
    }

    private static func writeSystemArrow(to url: URL, fileName: String) throws -> CursorSprite {
        let cursor = NSCursor.arrow
        let image = cursor.image
        let hotspot = cursor.hotSpot
        guard image.size.width > 0, image.size.height > 0 else {
            throw OpenRecordError.io("System arrow cursor has an empty image.")
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw OpenRecordError.io("Could not encode the system arrow cursor.")
        }
        try png.write(to: url, options: .atomic)

        let pixelWidth = Double(max(rep.pixelsWide, 1))
        let pixelHeight = Double(max(rep.pixelsHigh, 1))
        let scaleX = pixelWidth / Double(image.size.width)
        let scaleY = pixelHeight / Double(image.size.height)
        return CursorSprite(
            id: CaptureMediaFormat.defaultCursorSpriteID,
            hotspot: Point2D(x: Double(hotspot.x) * scaleX, y: Double(hotspot.y) * scaleY),
            pngRelativePath: "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(fileName)",
            standardSize: Size2D(width: Double(image.size.width), height: Double(image.size.height))
        )
    }

    private static func writeDrawnArrow(to url: URL, fileName: String) throws -> CursorSprite {
        let pixelSize = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OpenRecordError.io("Could not create a cursor sprite bitmap.")
        }

        ctx.translateBy(x: 0, y: CGFloat(pixelSize))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(1.25)
        ctx.setLineJoin(.miter)

        ctx.move(to: CGPoint(x: 1.5, y: 1.5))
        ctx.addLine(to: CGPoint(x: 1.5, y: 24))
        ctx.addLine(to: CGPoint(x: 7, y: 18.5))
        ctx.addLine(to: CGPoint(x: 12, y: 29.5))
        ctx.addLine(to: CGPoint(x: 15.5, y: 28))
        ctx.addLine(to: CGPoint(x: 10, y: 16.5))
        ctx.addLine(to: CGPoint(x: 18.5, y: 16.5))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)

        guard let cgImage = ctx.makeImage() else {
            throw OpenRecordError.io("Could not rasterize the default cursor sprite.")
        }
        try writePNG(cgImage, to: url)

        return CursorSprite(
            id: CaptureMediaFormat.defaultCursorSpriteID,
            hotspot: Point2D(x: 1.5, y: 1.5),
            pngRelativePath: "\(ProjectLayout.recordingDirectoryName)/\(ProjectLayout.cursorsDirectoryName)/\(fileName)",
            standardSize: Size2D(width: Double(pixelSize), height: Double(pixelSize))
        )
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OpenRecordError.io("Could not create a PNG destination for the cursor sprite.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OpenRecordError.io("Could not write the cursor sprite PNG.")
        }
    }
}
