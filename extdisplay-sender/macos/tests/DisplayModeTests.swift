// SPDX-License-Identifier: GPL-3.0-or-later
// Pure unit tests for VirtualDisplay.scaledModes and Mitchell-Netravali
// CIBicubicScaleTransform scaling. No WindowServer display is created and no
// TCC permissions or live session are touched.
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

enum SenderLog {
    static func info(_ text: String) {}
}

@main
enum DisplayModeTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func testScaledModes() {
        let m4k = VirtualDisplay.scaledModes(panelWide: 3840, panelHigh: 2160, scale: 2, maxPixelsPerAxis: 8192)
        let dims4k = m4k.map { "\($0.width)x\($0.height)" }
        check(dims4k == ["1920x1080", "2400x1350", "2880x1620", "3360x1890", "3840x2160"],
              "publishes 5 proportional HiDPI steps from 1920x1080@2x to 3840x2160 for a 4K panel")
        let mm4k = VirtualDisplay.syntheticMillimeters(for: m4k)
        check(mm4k.width > 550 && mm4k.width < 800 && mm4k.height > 300 && mm4k.height < 450,
              "derives synthetic physical size for 4K around 110 pt-DPI (\(Int(mm4k.width))x\(Int(mm4k.height))mm)")

        let m2x = VirtualDisplay.scaledModes(panelWide: 2160, panelHigh: 1440, scale: 2, maxPixelsPerAxis: 8192)
        let dims2x = m2x.map { "\($0.width)x\($0.height)" }
        check(dims2x == ["1080x720", "1350x900", "1620x1080", "1890x1260", "2160x1440"],
              "publishes 5 proportional HiDPI steps for a 2160x1440 panel")

        let m1080 = VirtualDisplay.scaledModes(panelWide: 1920, panelHigh: 1080, scale: 2, maxPixelsPerAxis: 8192)
        check(m1080.count == 5 && m1080.allSatisfy { $0.width >= 648 && $0.height >= 648 }
              && m1080.last!.width * 2 >= 3840 && m1080.contains(where: { $0.width == 1920 && $0.height == 1080 }),
              "publishes 5 valid >=648pt HiDPI steps with >=3840 backing for 1920x1080")

        let m1366 = VirtualDisplay.scaledModes(panelWide: 1366, panelHigh: 768, scale: 2, maxPixelsPerAxis: 8192)
        check(m1366.count == 5 && m1366.allSatisfy { $0.width >= 648 && $0.height >= 648 }
              && m1366.last!.width * 2 >= 3840 && m1366.contains(where: { $0.width == 1366 && $0.height == 768 }),
              "publishes 5 valid HiDPI steps including 1:1 1366x768 for non-div4 panels")

        let mPortrait = VirtualDisplay.scaledModes(panelWide: 1080, panelHigh: 1920, scale: 2, maxPixelsPerAxis: 8192)
        check(mPortrait.count == 5 && mPortrait.allSatisfy { $0.width >= 648 && $0.height >= 648 }
              && mPortrait.last!.height * 2 >= 3840,
              "publishes 5 valid HiDPI steps for portrait 1080x1920 panels")

        let m1x = VirtualDisplay.scaledModes(panelWide: 512, panelHigh: 384, scale: 1, maxPixelsPerAxis: 8192)
        check(m1x.count == 1 && m1x[0].width == 512 && m1x[0].height == 384,
              "keeps a single 1:1 mode on 1x panels")

        let capped = VirtualDisplay.scaledModes(panelWide: 3840, panelHigh: 2160, scale: 2, maxPixelsPerAxis: 5120)
        check(capped.allSatisfy { $0.width * 2 <= 5120 && $0.height * 2 <= 5120 } && !capped.isEmpty,
              "omits scaled modes exceeding descriptor pixel capacity")
    }

    static func testMitchellScaling() {
        let srcW = 320, srcH = 240
        let dstW = 200, dstH = 150
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var srcOpt: CVPixelBuffer?, dstOpt: CVPixelBuffer?
        CVPixelBufferCreate(nil, srcW, srcH, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &srcOpt)
        CVPixelBufferCreate(nil, dstW, dstH, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dstOpt)
        guard let src = srcOpt, let dst = dstOpt else {
            check(false, "allocates offscreen BGRA pixel buffers for Mitchell scaling")
            return
        }
        CVPixelBufferLockBaseAddress(src, [])
        if let base = CVPixelBufferGetBaseAddress(src) {
            let bpr = CVPixelBufferGetBytesPerRow(src)
            for y in 0..<srcH {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<srcW {
                    let v: UInt8 = (x == 160 || x == 161) ? 255 : 33
                    row[x * 4 + 0] = v
                    row[x * 4 + 1] = v
                    row[x * 4 + 2] = v
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(src, [])

        guard let filter = CIFilter(name: "CIBicubicScaleTransform") else {
            check(false, "CIBicubicScaleTransform filter is available")
            return
        }
        let input = CIImage(cvPixelBuffer: src, options: [.colorSpace: NSNull()]).clampedToExtent()
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(Double(dstW) / Double(srcW), forKey: kCIInputScaleKey)
        filter.setValue((Double(dstH) / Double(srcH)) / (Double(dstW) / Double(srcW)), forKey: "inputAspectRatio")
        filter.setValue(1.0 / 3.0, forKey: "inputB")
        filter.setValue(1.0 / 3.0, forKey: "inputC")
        guard let out = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: dstW, height: dstH)) else {
            check(false, "produces cropped Mitchell output image")
            return
        }
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ctx.render(out, to: dst, bounds: CGRect(x: 0, y: 0, width: dstW, height: dstH), colorSpace: nil)

        CVPixelBufferLockBaseAddress(dst, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(dst) else {
            check(false, "reads scaled output pixels")
            return
        }
        let bpr = CVPixelBufferGetBytesPerRow(dst)
        let rowMid = base.advanced(by: (dstH / 2) * bpr).assumingMemoryBound(to: UInt8.self)
        var minLuma = 255, maxLuma = 0
        for x in 0..<dstW {
            let r = Int(rowMid[x * 4 + 2])
            if r < minLuma { minLuma = r }
            if r > maxLuma { maxLuma = r }
        }
        let cornerR = Int(base.assumingMemoryBound(to: UInt8.self)[2])
        check(minLuma >= 28 && maxLuma >= 220,
              "Mitchell downscale preserves stroke contrast without dark halo ringing (min=\(minLuma), max=\(maxLuma))")
        check(cornerR == 33, "clamped extent avoids dark border bleed at frame edges (corner=\(cornerR))")
    }

    static func testModeDB() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("locachy-mode-db-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = DisplayModeDB(fileURL: tmp)
        let baseHello = """
        {"type":"hello","pv":3,"locachy":1,"device":"LOCachy","host":"cf-fv1","model":"CF-FV1","pixelsWide":2160,"pixelsHigh":1440,"scale":2.0,"panel":{"width":2160,"height":1440,"scale":2.0},"displayMaxFrameRate":60,"extendedOnly":true,"videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":4096,"maxFramesPerSecond":60}],"input":["key","button","cancel","pointer","scroll"]}
        """
        guard let fv1 = try? Panel(hello: Wire.object(Data(baseHello.utf8))),
              let x230 = try? Panel(hello: Wire.object(Data(baseHello.replacingOccurrences(of: "\"host\":\"cf-fv1\",\"model\":\"CF-FV1\"", with: "\"host\":\"x230\",\"model\":\"2325\"").utf8))) else {
            check(false, "parses named receiver hellos for DisplayModeDB tests")
            return
        }
        let allowed = VirtualDisplay.scaledModes(panelWide: 2160, panelHigh: 1440, scale: 2, maxPixelsPerAxis: 8192)
            .map { (Int($0.width), Int($0.height)) }
        check(db.lookup(for: fv1, allowedPointSizes: allowed) == nil,
              "returns nil for an unseen receiver (defaults to 1:1)")
        let chosen = SavedDisplayMode(pointsWide: 1620, pointsHigh: 1080, pixelsWide: 3240, pixelsHigh: 2160)
        db.save(for: fv1, mode: chosen, allowedPointSizes: allowed)
        let dbReloaded = DisplayModeDB(fileURL: tmp)
        check(dbReloaded.lookup(for: fv1, allowedPointSizes: allowed) == chosen,
              "persists and restores chosen scaling mode by host, model, and panel")
        check(dbReloaded.lookup(for: x230, allowedPointSizes: allowed) == nil,
              "keeps scaling choices isolated across different host/model receivers")
        let bogus = SavedDisplayMode(pointsWide: 1235, pointsHigh: 823, pixelsWide: 2470, pixelsHigh: 1646)
        dbReloaded.save(for: x230, mode: bogus, allowedPointSizes: allowed)
        check(dbReloaded.lookup(for: x230, allowedPointSizes: allowed) == nil,
              "rejects invalid scaling modes outside allowedModes")
    }

    static func main() {
        testScaledModes()
        testMitchellScaling()
        testModeDB()
        if failures != 0 {
            print("FAIL: \(failures) display mode test(s)")
            exit(1)
        }
        print("PASS: all display mode tests")
    }
}
