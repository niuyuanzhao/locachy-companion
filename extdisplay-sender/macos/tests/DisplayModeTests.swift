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
        let m2x = VirtualDisplay.scaledModes(pointsWide: 1080, pointsHigh: 720, scale: 2, maxPixelsPerAxis: 8192)
        let dims2x = m2x.map { "\($0.width)x\($0.height)" }
        check(dims2x == ["1080x720", "1234x822", "1440x960", "1728x1152", "2160x1440"],
              "publishes 5 proportional HiDPI steps for a 2160x1440 panel")

        let m1080 = VirtualDisplay.scaledModes(pointsWide: 960, pointsHigh: 540, scale: 2, maxPixelsPerAxis: 8192)
        let dims1080 = m1080.map { "\($0.width)x\($0.height)" }
        check(dims1080 == ["960x540", "1096x616", "1280x720", "1536x864", "1920x1080"],
              "publishes 5 proportional HiDPI steps for a 1920x1080 panel")

        let m1x = VirtualDisplay.scaledModes(pointsWide: 1366, pointsHigh: 768, scale: 1, maxPixelsPerAxis: 8192)
        check(m1x.count == 1 && m1x[0].width == 1366 && m1x[0].height == 768,
              "keeps a single 1:1 mode on 1x panels")

        let capped = VirtualDisplay.scaledModes(pointsWide: 1920, pointsHigh: 1080, scale: 2, maxPixelsPerAxis: 5120)
        let dimsCapped = capped.map { "\($0.width)x\($0.height)" }
        check(dimsCapped == ["1920x1080", "2194x1234", "2560x1440"],
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

    static func main() {
        testScaledModes()
        testMitchellScaling()
        if failures != 0 {
            print("FAIL: \(failures) display mode test(s)")
            exit(1)
        }
        print("PASS: all display mode tests")
    }
}
