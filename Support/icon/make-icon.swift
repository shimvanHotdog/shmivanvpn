// Generates the app icon and menu bar avatar from a photo.
//   swift Support/icon/make-icon.swift Support/icon/face-source.jpg Support/icon
// Outputs AppIcon.icns and menubar-face.png into the output folder.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon.swift <photo> <outdir>"); exit(64) }
let outDir = URL(fileURLWithPath: args[2])
guard let photo = CIImage(contentsOf: URL(fileURLWithPath: args[1]), options: [.applyOrientationProperty: true]) else {
    print("cannot read photo"); exit(1)
}
let ctx = CIContext()
let W = photo.extent.width, H = photo.extent.height

// 1. Face rectangle (Vision coordinates are normalized, origin bottom-left like CoreImage).
let faceReq = VNDetectFaceRectanglesRequest()
try VNImageRequestHandler(ciImage: photo).perform([faceReq])
guard let face = faceReq.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox else {
    print("no face found"); exit(1)
}
let faceRect = CGRect(x: face.minX * W, y: face.minY * H, width: face.width * W, height: face.height * H)
print("face:", faceRect.integral)

// 2. Person cutout.
let segReq = VNGeneratePersonSegmentationRequest()
segReq.qualityLevel = .accurate
segReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
try VNImageRequestHandler(ciImage: photo).perform([segReq])
guard let maskBuffer = segReq.results?.first?.pixelBuffer else { print("segmentation failed"); exit(1) }
var mask = CIImage(cvPixelBuffer: maskBuffer)
mask = mask.transformed(by: CGAffineTransform(scaleX: W / mask.extent.width, y: H / mask.extent.height))
    .applyingGaussianBlur(sigma: 1.2).cropped(to: photo.extent)
let cutout = photo.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
])
// Slight pop: a touch more contrast/saturation so it reads at small sizes.
let graded = cutout.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.12, kCIInputContrastKey: 1.06])

func render(_ image: CIImage, size: Int) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = ctx.createCGImage(image, from: CGRect(x: 0, y: 0, width: size, height: size))!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSImage(cgImage: cg, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: size, height: size))
    img.addRepresentation(rep)
    return img
}

func png(_ image: NSImage) -> Data {
    let rep = image.representations.first as! NSBitmapImageRep
    return rep.representation(using: .png, properties: [:])!
}

/// Places the cutout so the face has a given height and center within an S×S canvas, over a background.
func composite(size S: CGFloat, faceHeightFraction: CGFloat, faceCenterY: CGFloat, background: CIImage) -> CIImage {
    let scale = S * faceHeightFraction / faceRect.height
    let tx = S / 2 - faceRect.midX * scale
    let ty = S * faceCenterY - faceRect.midY * scale
    let placed = graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(.init(translationX: tx, y: ty)))
    return placed.composited(over: background).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}

func gradient(_ S: CGFloat, _ top: CIColor, _ bottom: CIColor) -> CIImage {
    CIFilter.linearGradient().then {
        $0.point0 = CGPoint(x: 0, y: S); $0.color0 = top
        $0.point1 = CGPoint(x: S * 0.3, y: 0); $0.color1 = bottom
    }.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
}

extension CIFilter {
    func then(_ f: (Self) -> Void) -> Self { f(self); return self }
}

// 3. App icon: macOS squircle (824pt body on a 1024 canvas), deep-blue→violet gradient.
let S: CGFloat = 1024
let body: CGFloat = 824
let bg = gradient(body, CIColor(red: 0.30, green: 0.55, blue: 1.0), CIColor(red: 0.42, green: 0.18, blue: 0.78))
let iconBody = composite(size: body, faceHeightFraction: 0.46, faceCenterY: 0.47, background: bg)
let bodyImage = render(iconBody, size: Int(body))

/// Draws into an exact-pixel bitmap (NSImage.lockFocus would use the screen's 2x backing scale).
func bitmap(_ px: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let masterRep = bitmap(Int(S)) {
    let inset = (S - body) / 2
    let rect = NSRect(x: inset, y: inset, width: body, height: body)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: body * 0.225, yRadius: body * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    bodyImage.draw(in: rect)
    // Glassy top highlight and a hairline rim.
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: inset, y: inset + body * 0.55, width: body, height: body * 0.45), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    squircle.lineWidth = 3; squircle.stroke()
}
let master = NSImage(size: NSSize(width: S, height: S))
master.addRepresentation(masterRep)

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = bitmap(px) { master.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let icns = outDir.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run(); p.waitUntilExit()
try masterRep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("AppIcon-1024.png"))
try? FileManager.default.removeItem(at: iconset)

// 4. Menu bar avatar: tight face crop on the same gradient; the app clips it to a circle at runtime.
let M: CGFloat = 128
let avatar = composite(size: M, faceHeightFraction: 0.62, faceCenterY: 0.50,
                       background: gradient(M, CIColor(red: 0.30, green: 0.55, blue: 1.0), CIColor(red: 0.42, green: 0.18, blue: 0.78)))
try png(render(avatar, size: Int(M))).write(to: outDir.appendingPathComponent("menubar-face.png"))
print("wrote", icns.path, "and menubar-face.png")
