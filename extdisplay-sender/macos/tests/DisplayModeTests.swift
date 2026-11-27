// SPDX-License-Identifier: GPL-3.0-or-later
// Pure unit tests for VirtualDisplay.scaledModes, MetalPerformanceShaders
// downscaling, and frame pacing. No WindowServer display is created and no
// TCC permissions or live session are touched.
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

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

    static func makeBGRAPixelBuffer(width: Int, height: Int, fill: (Int, Int) -> UInt8) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var bufOpt: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bufOpt) == kCVReturnSuccess,
              let buf = bufOpt else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let v = fill(x, y)
                    row[x * 4 + 0] = v
                    row[x * 4 + 1] = v
                    row[x * 4 + 2] = v
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buf
    }

    static func testImageScaling() {
        let srcW = 320, srcH = 240
        let dstW = 200, dstH = 150
        guard let src = makeBGRAPixelBuffer(width: srcW, height: srcH, fill: { x, _ in (x == 160 || x == 161) ? 255 : 33 }),
              let dstMetal = makeBGRAPixelBuffer(width: dstW, height: dstH, fill: { _, _ in 0 }),
              let dstCI = makeBGRAPixelBuffer(width: dstW, height: dstH, fill: { _, _ in 0 }) else {
            check(false, "allocates offscreen BGRA pixel buffers for MPS scaling")
            return
        }

        // 1. Production MetalPerformanceShaders (MPSImageLanczosScale) scaler.
        guard let scaler = MetalImageScaler() else {
            check(false, "initializes MetalImageScaler (MPSImageLanczosScale) pipeline")
            return
        }
        let metalOK = scaler.scale(from: src, to: dstMetal)
        check(metalOK, "MetalImageScaler scales BGRA pixel buffer via MPSImageLanczosScale")

        CVPixelBufferLockBaseAddress(dstMetal, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(dstMetal) {
            let bpr = CVPixelBufferGetBytesPerRow(dstMetal)
            let rowMid = base.advanced(by: (dstH / 2) * bpr).assumingMemoryBound(to: UInt8.self)
            var maxLuma = 0
            var peakX = -1
            for x in 0..<dstW {
                let r = Int(rowMid[x * 4 + 2])
                if r > maxLuma {
                    maxLuma = r
                    peakX = x
                }
            }
            var maxBgDrift = 0
            for x in 0..<dstW where abs(x - peakX) > 6 {
                let drift = abs(Int(rowMid[x * 4 + 2]) - 33)
                if drift > maxBgDrift { maxBgDrift = drift }
            }
            let cornerR = Int(base.assumingMemoryBound(to: UInt8.self)[2])
            let cornerA = Int(base.assumingMemoryBound(to: UInt8.self)[3])
            check(maxLuma >= 200 && abs(peakX - dstW / 2) <= 2,
                  "MPSImageLanczosScale horizontal downscale preserves centered stroke contrast (max=\(maxLuma), peakX=\(peakX))")
            check(maxBgDrift <= 1 && abs(cornerR - 33) <= 1 && cornerA == 255,
                  "MPSImageLanczosScale edge clamping avoids dark border bleed and preserves alpha (bgDrift=\(maxBgDrift), corner=\(cornerR), alpha=\(cornerA))")
        } else {
            check(false, "reads MPS scaled output pixels")
        }
        CVPixelBufferUnlockBaseAddress(dstMetal, .readOnly)

        // 2. Vertical stroke test + dynamic resize (400x300 -> 200x150).
        if let srcVert = makeBGRAPixelBuffer(width: 400, height: 300, fill: { _, y in (y == 150 || y == 151) ? 255 : 33 }),
           let dstVert = makeBGRAPixelBuffer(width: dstW, height: dstH, fill: { _, _ in 0 }) {
            let vertOK = scaler.scale(from: srcVert, to: dstVert)
            CVPixelBufferLockBaseAddress(dstVert, .readOnly)
            if vertOK, let base = CVPixelBufferGetBaseAddress(dstVert) {
                let bpr = CVPixelBufferGetBytesPerRow(dstVert)
                var maxLuma = 0
                var peakY = -1
                let x = dstW / 2
                for y in 0..<dstH {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let r = Int(row[x * 4 + 2])
                    if r > maxLuma {
                        maxLuma = r
                        peakY = y
                    }
                }
                var maxBgDrift = 0
                for y in 0..<dstH where abs(y - peakY) > 6 {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    let drift = abs(Int(row[x * 4 + 2]) - 33)
                    if drift > maxBgDrift { maxBgDrift = drift }
                }
                let bottomRow = base.advanced(by: (dstH - 1) * bpr).assumingMemoryBound(to: UInt8.self)
                let bottomR = Int(bottomRow[2])
                let bottomA = Int(bottomRow[3])
                check(maxLuma >= 195 && abs(peakY - dstH / 2) <= 2 && maxBgDrift <= 1 && abs(bottomR - 33) <= 1 && bottomA == 255,
                      "MPSImageLanczosScale vertical pass handles dynamic resize cleanly (max=\(maxLuma), peakY=\(peakY), bgDrift=\(maxBgDrift), edge=\(bottomR), alpha=\(bottomA))")
            } else {
                check(false, "MPSImageLanczosScale vertical pass with dynamic resize")
            }
            CVPixelBufferUnlockBaseAddress(dstVert, .readOnly)
        } else {
            check(false, "allocates vertical stroke buffers for MPS scaling")
        }
        scaler.flush()

        // 3. CoreImage CILanczosScaleTransform fallback still passes contrast and edge invariants.
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            check(false, "CILanczosScaleTransform fallback filter is available")
            return
        }
        let input = CIImage(cvPixelBuffer: src, options: [.colorSpace: NSNull()]).clampedToExtent()
        let scaleY = Double(dstH) / Double(srcH)
        let scaleX = Double(dstW) / Double(srcW)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / max(1e-6, scaleY), forKey: kCIInputAspectRatioKey)
        guard let out = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: dstW, height: dstH)) else {
            check(false, "produces cropped CoreImage Lanczos fallback output")
            return
        }
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ctx.render(out, to: dstCI, bounds: CGRect(x: 0, y: 0, width: dstW, height: dstH), colorSpace: nil)

        CVPixelBufferLockBaseAddress(dstCI, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstCI, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(dstCI) else {
            check(false, "reads CoreImage fallback output pixels")
            return
        }
        let bpr = CVPixelBufferGetBytesPerRow(dstCI)
        let rowMid = base.advanced(by: (dstH / 2) * bpr).assumingMemoryBound(to: UInt8.self)
        var maxLuma = 0
        var peakX = -1
        for x in 0..<dstW {
            let r = Int(rowMid[x * 4 + 2])
            if r > maxLuma {
                maxLuma = r
                peakX = x
            }
        }
        var maxBgDrift = 0
        for x in 0..<dstW where abs(x - peakX) > 6 {
            let drift = abs(Int(rowMid[x * 4 + 2]) - 33)
            if drift > maxBgDrift { maxBgDrift = drift }
        }
        let cornerR = Int(base.assumingMemoryBound(to: UInt8.self)[2])
        let cornerA = Int(base.assumingMemoryBound(to: UInt8.self)[3])
        check(maxLuma >= 200 && abs(peakX - dstW / 2) <= 2,
              "CoreImage Lanczos fallback preserves centered stroke contrast (max=\(maxLuma), peakX=\(peakX))")
        check(maxBgDrift <= 1 && abs(cornerR - 33) <= 1 && cornerA == 255,
              "CoreImage clamped extent avoids dark border bleed at frame edges (bgDrift=\(maxBgDrift), corner=\(cornerR), alpha=\(cornerA))")
    }

    static func testFramePacer() {
        var pacer = FramePacer(fps: 60)
        // minInterval = 0.45 / 60 = 0.0075 s (7.5 ms).
        check(abs(pacer.minInterval - 0.0075) < 0.0001,
              "FramePacer derives 7.5 ms minimum interval at 60 Hz")

        // First frame admitted immediately even at t = 0.0.
        check(pacer.tryAdmit(now: 0.0, transportCanAccept: true, forceAdmission: false) == .admit
              && pacer.inFlightEncodes == 1,
              "FramePacer admits first frame immediately")

        // Frame arriving 3 ms later is paced for exact remaining 4.5 ms, not 16 ms.
        if case .paced(let delay) = pacer.tryAdmit(now: 0.003, transportCanAccept: true, forceAdmission: false) {
            check(abs(delay - 0.0045) < 0.0002 && pacer.inFlightEncodes == 1,
                  "FramePacer returns exact remaining delay (\(String(format: "%.2f", delay * 1000))ms) when inside minInterval")
        } else {
            check(false, "FramePacer returns .paced(delay:) when inside minInterval")
        }

        // Frame arriving 7.2 ms later is clamped to >= 1 ms minimum pacing delay.
        if case .paced(let delay) = pacer.tryAdmit(now: 0.0072, transportCanAccept: true, forceAdmission: false) {
            check(abs(delay - FramePacer.minimumPacedDelay) < 0.0001,
                  "FramePacer clamps tiny remaining pacing delay to 1 ms floor")
        } else {
            check(false, "FramePacer clamps tiny remaining pacing delay to 1 ms floor")
        }

        // Second frame at 16.67 ms enters VT concurrently while frame 1 is still encoding (2 in flight).
        check(pacer.tryAdmit(now: 0.01667, transportCanAccept: true, forceAdmission: false) == .admit
              && pacer.inFlightEncodes == 2,
              "FramePacer allows up to 2 frames in flight in VideoToolbox")

        // Third frame while 2 are encoding is rejected as .busy.
        check(pacer.tryAdmit(now: 0.03333, transportCanAccept: true, forceAdmission: false) == .busy
              && pacer.inFlightEncodes == 2,
              "FramePacer rejects a 3rd concurrent encode as .busy")

        // Frame 1 finishes VT encode and hands off to sendQueue -> encode slot frees immediately.
        pacer.finishEncode(handoffToSend: true)
        check(pacer.inFlightEncodes == 1 && pacer.inFlightSends == 1,
              "FramePacer transfers completed encode atomically to send slot")
        check(pacer.tryAdmit(now: 0.03333, transportCanAccept: true, forceAdmission: false) == .admit
              && pacer.inFlightEncodes == 2,
              "FramePacer admits frame 3 as soon as frame 1 hands off to sendQueue")

        // Send queue backpressure caps at 2 in-flight sends; transport backpressure also returns .busy.
        pacer.finishEncode(handoffToSend: true)
        check(pacer.inFlightEncodes == 1 && pacer.inFlightSends == 2
              && pacer.tryAdmit(now: 0.050, transportCanAccept: true, forceAdmission: false) == .busy,
              "FramePacer respects maxInFlightSends backpressure")
        pacer.finishSend()
        check(pacer.inFlightSends == 1
              && pacer.tryAdmit(now: 0.050, transportCanAccept: false, forceAdmission: false) == .busy,
              "FramePacer respects transport.canAcceptVideo backpressure")

        // forceAdmission bypasses minInterval (for timer expiry) while still enforcing capacity.
        check(pacer.tryAdmit(now: 0.034, transportCanAccept: true, forceAdmission: true) == .admit
              && pacer.inFlightEncodes == 2,
              "FramePacer honors forceAdmission when a slot is free")

        // Underflow protection.
        pacer.finishEncode(handoffToSend: false)
        pacer.finishEncode(handoffToSend: false)
        pacer.finishEncode(handoffToSend: false)
        pacer.finishSend()
        pacer.finishSend()
        check(pacer.inFlightEncodes == 0 && pacer.inFlightSends == 0,
              "FramePacer clamps slot counters at zero on extra completions")
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

    static func testDisplayIdentity() {
        let baseHello = """
        {"type":"hello","pv":3,"locachy":1,"device":"LOCachy","host":"x1-yoga","model":"20QD0000US","hostId":"hostid-x1yoga-001","pixelsWide":3840,"pixelsHigh":2160,"scale":2.0,"panel":{"width":3840,"height":2160,"scale":2.0},"displayMaxFrameRate":60,"extendedOnly":true,"videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":4096,"maxFramesPerSecond":60}],"input":["key","button","cancel","pointer","scroll"]}
        """
        let secondHello = baseHello
            .replacingOccurrences(of: "\"host\":\"x1-yoga\"", with: "\"host\":\"workstation\"")
            .replacingOccurrences(of: "\"model\":\"20QD0000US\"", with: "\"model\":\"CustomDesktop\"")
            .replacingOccurrences(of: "\"hostId\":\"hostid-x1yoga-001\"", with: "\"hostId\":\"hostid-desk-002\"")
        let defaultHostHello = baseHello
            .replacingOccurrences(of: "\"host\":\"x1-yoga\"", with: "\"host\":\"locachy\"")
        let legacyHello = """
        {"type":"hello","pv":3,"locachy":1,"device":"LOCachy","pixelsWide":1920,"pixelsHigh":1080,"scale":2.0,"panel":{"width":1920,"height":1080,"scale":2.0},"displayMaxFrameRate":60,"extendedOnly":true,"videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":4096,"maxFramesPerSecond":60}],"input":["key","button","cancel","pointer","scroll"]}
        """
        guard let p1 = try? Panel(hello: Wire.object(Data(baseHello.utf8))),
              let p1Again = try? Panel(hello: Wire.object(Data(baseHello.utf8))),
              let p2 = try? Panel(hello: Wire.object(Data(secondHello.utf8))),
              let pDefaultHost = try? Panel(hello: Wire.object(Data(defaultHostHello.utf8))),
              let pLegacy = try? Panel(hello: Wire.object(Data(legacyHello.utf8))) else {
            check(false, "parses hello payloads for display identity tests")
            return
        }

        let id1 = VirtualDisplayIdentity.derive(from: p1)
        let id1Again = VirtualDisplayIdentity.derive(from: p1Again)
        let id2 = VirtualDisplayIdentity.derive(from: p2)
        let idDefaultHost = VirtualDisplayIdentity.derive(from: pDefaultHost)
        let idLegacy = VirtualDisplayIdentity.derive(from: pLegacy)

        check(id1 == id1Again && id1.serialNum != 0,
              "VirtualDisplayIdentity.derive is deterministic and non-zero for the same receiver")
        check(id1.serialNum != id2.serialNum && id1.name == "LOCachy-x1-yoga" && id2.name == "LOCachy-workstation",
              "VirtualDisplayIdentity.derive produces distinct serialNum and LOCachy-<host> labels for two receivers")
        check(idDefaultHost.name == "LOCachy-20QD0000US",
              "VirtualDisplayIdentity.derive avoids LOCachy-locachy by falling back to machine model")
        check((id1.productID & 0xFF00) == 0x4C00 && (id2.productID & 0xFF00) == 0x4C00,
              "VirtualDisplayIdentity.derive places productID inside 0x4C00...0x4CFF")
        check(idLegacy.name == "LOCachy" && idLegacy.serialNum != 0,
              "VirtualDisplayIdentity.derive falls back cleanly when host and hostId are omitted")

        // ActiveDisplayRegistry collision avoidance when two legacy identical receivers connect simultaneously.
        let reg = ActiveDisplayRegistry()
        let firstClaim = reg.claim(preferred: idLegacy)
        let secondClaim = reg.claim(preferred: idLegacy)
        check(firstClaim.serialNum == idLegacy.serialNum
              && secondClaim.serialNum != firstClaim.serialNum
              && reg.isActive(serialNum: firstClaim.serialNum)
              && reg.isActive(serialNum: secondClaim.serialNum),
              "ActiveDisplayRegistry assigns a non-colliding serialNum when a preferred serial is already active")
        reg.release(serialNum: firstClaim.serialNum)
        let reclaimed = reg.claim(preferred: idLegacy)
        check(reclaimed.serialNum == idLegacy.serialNum,
              "ActiveDisplayRegistry releases serialNum cleanly for reuse on reconnect")
        reg.release(serialNum: secondClaim.serialNum)
        reg.release(serialNum: reclaimed.serialNum)
    }

    static func testVirtualDisplayResetPolicy() {
        final class Token {}
        let tokenA = Token()
        let tokenB = Token()
        let a = ObjectIdentifier(tokenA)
        let b = ObjectIdentifier(tokenB)
        var policy = VirtualDisplayResetPolicy()

        check(!policy.shouldResetBeforeAttach && !policy.partialDisconnectObserved,
              "VirtualDisplayResetPolicy starts idle with no reset required for first display")
        policy.recordAttach(a)
        check(policy.shouldResetBeforeAttach && !policy.partialDisconnectObserved,
              "VirtualDisplayResetPolicy requests reset when a second virtual display attaches alongside an active one")

        // Single display disconnect leaves zero displays: next fresh attach needs no reset.
        policy.recordDetach(a)
        check(!policy.shouldResetBeforeAttach && !policy.partialDisconnectObserved,
              "VirtualDisplayResetPolicy clears reset state once all virtual displays disconnect")

        // Reset sequence when B joins A: drain to zero, attach A and B together.
        policy.recordAttach(a)
        policy.recordResetDrained()
        check(!policy.shouldResetBeforeAttach && policy.activeTokens.isEmpty,
              "VirtualDisplayResetPolicy clears active tokens after draining displays to zero")
        policy.recordAttach(a)
        policy.recordAttach(b)

        // Partial disconnect (B leaves while A stays): marks partial disconnect, keeps A active.
        policy.recordDetach(b)
        check(policy.partialDisconnectObserved && policy.shouldResetBeforeAttach && policy.activeTokens == [a],
              "VirtualDisplayResetPolicy marks partial disconnect when one virtual display detaches while another remains")

        // Remaining display also detaches: table naturally resets to zero.
        policy.recordDetach(a)
        check(!policy.partialDisconnectObserved && !policy.shouldResetBeforeAttach && policy.activeTokens.isEmpty,
              "VirtualDisplayResetPolicy clears partial disconnect once the last virtual display detaches")
    }

    static func main() {
        testScaledModes()
        testImageScaling()
        testFramePacer()
        testModeDB()
        testDisplayIdentity()
        testVirtualDisplayResetPolicy()
        if failures != 0 {
            print("FAIL: \(failures) display mode test(s)")
            exit(1)
        }
        print("PASS: all display mode tests")
    }
}
