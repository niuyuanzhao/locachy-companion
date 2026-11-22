// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import Metal
import ScreenCaptureKit
import VideoToolbox

enum SenderLog {
    static func info(_ text: String) { fputs("locachy-macos: \(text)\n", stderr) }
}

@available(macOS 14.0, *)
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let transport: SecureTransport
    private let panel: Panel
    private let sampleQueue = DispatchQueue(label: "locachy.macos.capture", qos: .userInteractive)
    let inputQueue: DispatchQueue
    private let lock = NSLock()
    private var display: VirtualDisplay?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var input: RemoteInput?
    private var modeTask: Task<Void, Never>?
    private var refineTimer: DispatchSourceTimer?
    private var pendingImage: CVImageBuffer?
    private var pendingPts: CMTime = .invalid
    private var stopped = false
    private var needsKeyframe = true
    private var encoding = false
    private var lastSubmit = 0.0
    private var encodeStart = 0.0
    private var cachedScrollScale = 1.0
    private var framesEncoded: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var totalEncodeMs = 0.0
    private var lastStatsLog = 0.0
    private let logPeriodicStats = ProcessInfo.processInfo.environment["LOCACHY_STATS"] == "1"
    private var activeCodec = "h264"
    private var recovering = false
    private var captureWidth = 0
    private var captureHeight = 0
    private var sleepAssertion: IOPMAssertionID = 0
    private var wakeAssertion: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?
    private var consecutiveEncodeErrors = 0
    private var reconfigRegistered = false
    private var reconfigContext: UnsafeMutableRawPointer?
    private lazy var ciContext: CIContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }()
    private var scalePool: CVPixelBufferPool?
    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init(transport: SecureTransport, panel: Panel,
         inputQueue: DispatchQueue = DispatchQueue(label: "locachy.macos.input", qos: .userInteractive)) {
        self.transport = transport
        self.panel = panel
        self.inputQueue = inputQueue
    }

    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let session = Unmanaged<CaptureSession>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { [weak session] in
            session?.refreshDisplayState()
        }
    }

    private func updateScrollScale(displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let scale = bounds.width > 0 ? bounds.width / Double(max(1, panel.width)) : 1.0
        lock.lock()
        cachedScrollScale = scale
        lock.unlock()
    }

    @MainActor
    private func refreshDisplayState() {
        if let display {
            updateScrollScale(displayID: display.displayID)
        }
        inputQueue.async { [weak self] in
            self?.input?.invalidateDisplayCache()
        }
    }

    // Main actor: CGVirtualDisplay installs its WindowServer callbacks on main.
    @MainActor
    func start() async throws {
        try Task.checkCancellation()
        IOPMAssertionDeclareUserActivity("LOCachy Extended Display" as CFString, kIOPMUserActiveLocal, &wakeAssertion)
        _ = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "LOCachy Extended Display" as CFString,
            &sleepAssertion)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "LOCachy Extended Display streaming"
        )
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard let plan = VirtualCanvasSizing.plan(pixelsWide: panel.width, pixelsHigh: panel.height, scale: panel.scale)
        else { throw SenderError("Receiver panel dimensions are unsupported") }
        let first = plan.bootstrap
        let allowedModes = VirtualDisplay.scaledModes(
            panelWide: panel.width, panelHigh: panel.height,
            scale: plan.requested.scale, maxPixelsPerAxis: plan.descriptorMaxPixelsPerAxis)
        let allowedPointSizes = allowedModes.map { (Int($0.width), Int($0.height)) }
        let millimeters = VirtualDisplay.syntheticMillimeters(for: allowedModes)
        let initialModes: [CGVirtualDisplayMode]? = (plan.requested == first) ? allowedModes : nil
        var createdDisplay: VirtualDisplay?
        for probe: UInt32 in 0..<8 {
            if let candidate = VirtualDisplay(
                name: "LOCachy", pointsWide: first.pointsWide, pointsHigh: first.pointsHigh,
                scale: first.scale, descriptorMaxPixelsPerAxis: plan.descriptorMaxPixelsPerAxis,
                sizeInMillimeters: millimeters, serialNum: 0x4C4F4301 + probe, productID: 0x4C4F + probe,
                modes: initialModes
            ) {
                createdDisplay = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let created = createdDisplay else { throw SenderError("CGVirtualDisplay is unavailable or rejected this mode") }
        display = created
        do {
            let id = created.displayID
            if plan.requested != first {
                guard await created.resize(pointsWide: plan.requested.pointsWide, pointsHigh: plan.requested.pointsHigh,
                                           scale: plan.requested.scale, modes: allowedModes, movingTo: nil) else {
                    throw SenderError("macOS rejected the receiver resolution")
                }
            }
            let defaultTarget: SavedDisplayMode
            let exactHiDPI = (panel.width / 2, panel.height / 2)
            let native1x = (panel.width & ~1, panel.height & ~1)
            if panel.scale == 2, min(panel.width, panel.height) >= 1296,
               allowedPointSizes.contains(where: { $0.0 == exactHiDPI.0 && $0.1 == exactHiDPI.1 }) {
                defaultTarget = SavedDisplayMode(
                    pointsWide: exactHiDPI.0, pointsHigh: exactHiDPI.1,
                    pixelsWide: exactHiDPI.0 * 2, pixelsHigh: exactHiDPI.1 * 2)
            } else if allowedPointSizes.contains(where: { $0.0 == native1x.0 && $0.1 == native1x.1 }) {
                defaultTarget = SavedDisplayMode(
                    pointsWide: native1x.0, pointsHigh: native1x.1,
                    pixelsWide: native1x.0, pixelsHigh: native1x.1)
            } else if let closest = allowedPointSizes.min(by: {
                abs($0.1 - panel.height) + abs($0.0 - panel.width) < abs($1.1 - panel.height) + abs($1.0 - panel.width)
            }) {
                defaultTarget = SavedDisplayMode(
                    pointsWide: closest.0, pointsHigh: closest.1,
                    pixelsWide: closest.0 * panel.scale, pixelsHigh: closest.1 * panel.scale)
            } else {
                defaultTarget = SavedDisplayMode(
                    pointsWide: plan.requested.pointsWide, pointsHigh: plan.requested.pointsHigh,
                    pixelsWide: plan.requested.pixelsWide, pixelsHigh: plan.requested.pixelsHigh)
            }
            var targetMode = DisplayModeDB.shared.lookup(for: panel, allowedPointSizes: allowedPointSizes) ?? defaultTarget
            for _ in 0..<20 {
                selectNativeMode(id: id, pointsWide: targetMode.pointsWide, pointsHigh: targetMode.pointsHigh,
                                 pixelsWide: targetMode.pixelsWide, pixelsHigh: targetMode.pixelsHigh)
                if let cur = CGDisplayCopyDisplayMode(id),
                   cur.width == targetMode.pointsWide, cur.height == targetMode.pointsHigh,
                   (cur.pixelWidth == targetMode.pixelsWide && cur.pixelHeight == targetMode.pixelsHigh
                    || targetMode.pointsWide == panel.width) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if let cur = CGDisplayCopyDisplayMode(id),
               cur.width != targetMode.pointsWide || cur.height != targetMode.pointsHigh,
               targetMode != defaultTarget {
                targetMode = defaultTarget
                for _ in 0..<20 {
                    selectNativeMode(id: id, pointsWide: targetMode.pointsWide, pointsHigh: targetMode.pointsHigh,
                                     pixelsWide: targetMode.pixelsWide, pixelsHigh: targetMode.pixelsHigh)
                    if let updated = CGDisplayCopyDisplayMode(id),
                       updated.width == targetMode.pointsWide, updated.height == targetMode.pointsHigh {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            guard CGDisplayIsInMirrorSet(id) != 1 else { throw SenderError("macOS placed the LOCachy display in a mirror set") }
            guard let cur = CGDisplayCopyDisplayMode(id),
                  cur.width == targetMode.pointsWide, cur.height == targetMode.pointsHigh else {
                throw SenderError("Virtual display did not enter the requested display mode")
            }
            let activeMode = SavedDisplayMode(
                pointsWide: cur.width, pointsHigh: cur.height,
                pixelsWide: cur.pixelWidth, pixelsHigh: cur.pixelHeight)
            let width = panel.width, height = panel.height
            let capW = cur.pixelWidth, capH = cur.pixelHeight
            captureWidth = capW
            captureHeight = capH
            let target = try await shareable(id)
            try Task.checkCancellation()
            try configureEncoder(width: width, height: height)
            updateScrollScale(displayID: id)
            let remoteInput = RemoteInput(displayID: id, queue: inputQueue)
            inputQueue.sync { self.input = remoteInput }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            if CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, ctx) == .success {
                reconfigContext = ctx
                reconfigRegistered = true
            }
            transport.onVideoDrained = { [weak self] in
                self?.sampleQueue.async { [weak self] in
                    self?.drainPendingFrame(forceAdmission: true)
                }
            }
            let filter = SCContentFilter(display: target, excludingWindows: [])
            let configuration = makeStreamConfiguration(width: capW, height: capH)
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            stream = capture
            transport.sendObject(["type": "streamConfig", "codec": activeCodec, "width": width,
                                  "height": height, "framesPerSecond": panel.fps])
            try await capture.startCapture()
            try Task.checkCancellation()
            startModeWatcher(id: id, initialTarget: activeMode, allowedPointSizes: allowedPointSizes)
            SenderLog.info("Extended display \(id) is active at \(activeMode.pointsWide)x\(activeMode.pointsHigh) (cap=\(capW)x\(capH), out=\(width)x\(height), \(activeCodec), \(panel.identityKey))")
        } catch {
            stop("Capture setup failed")
            throw error
        }
    }

    private func makeStreamConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, panel.fps)))
        configuration.queueDepth = 3
        let nativeSize = (width == panel.width && height == panel.height)
        if nativeSize && (panel.codec == "hevc420" || panel.codec == "h264" || activeCodec == "h264") {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        } else {
            // Keep full-chroma 32BGRA for 4:4:4 codecs and for scaled modes so
            // Metal Mitchell bicubic downscaling runs in RGB before 4:2:0 encoding.
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        }
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.shouldBeOpaque = true
        configuration.showsCursor = true
        return configuration
    }

    private func selectNativeMode(id: CGDirectDisplayID, pointsWide: Int, pointsHigh: Int, pixelsWide: Int, pixelsHigh: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let match = modes.first(where: {
                  $0.width == pointsWide && $0.height == pointsHigh
                      && $0.pixelWidth == pixelsWide && $0.pixelHeight == pixelsHigh
              }) ?? modes.first(where: { $0.width == pointsWide && $0.height == pointsHigh }) else { return }
        if let cur = CGDisplayCopyDisplayMode(id),
           cur.width == match.width, cur.height == match.height,
           cur.pixelWidth == match.pixelWidth, cur.pixelHeight == match.pixelHeight { return }
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            CGConfigureDisplayWithDisplayMode(config, id, match, nil)
            CGCompleteDisplayConfiguration(config, .forSession)
        }
    }

    @MainActor
    private func rebuildStream(id: CGDirectDisplayID, sourceWidth: Int, sourceHeight: Int) async {
        guard !stopped, !recovering else { return }
        recovering = true
        defer { recovering = false }
        try? await Task.sleep(for: .milliseconds(60))
        guard !stopped, let updated = try? await shareable(id) else { return }
        guard !stopped else { return }
        captureWidth = sourceWidth
        captureHeight = sourceHeight
        let cfg = makeStreamConfiguration(width: sourceWidth, height: sourceHeight)
        let filter = SCContentFilter(display: updated, excludingWindows: [])
        if let active = stream {
            do {
                try await active.updateContentFilter(filter)
                try await active.updateConfiguration(cfg)
                requestKeyframe()
                return
            } catch {
                // Fall through to full SCStream replacement if in-place update fails.
            }
        }
        let oldStream = stream
        let replacement = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            stream = replacement
            requestKeyframe()
            try await replacement.startCapture()
            if let oldStream, oldStream !== replacement {
                try? await oldStream.stopCapture()
            }
        } catch {
            if stream === replacement { stream = oldStream }
        }
    }

    @MainActor
    private func recoverStream() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard !stopped, let display else { return }
        let m = CGDisplayCopyDisplayMode(display.displayID)
        await rebuildStream(id: display.displayID,
                            sourceWidth: m?.pixelWidth ?? panel.width,
                            sourceHeight: m?.pixelHeight ?? panel.height)
    }

    @MainActor
    private func startModeWatcher(id: CGDirectDisplayID, initialTarget: SavedDisplayMode, allowedPointSizes: [(Int, Int)]) {
        let settleUntil = ProcessInfo.processInfo.systemUptime + 2.0
        var lastSize = CGSize(width: initialTarget.pointsWide, height: initialTarget.pointsHigh)
        var lastPixels = CGSize(width: initialTarget.pixelsWide, height: initialTarget.pixelsHigh)
        var correctedDuringSettle = false
        var tried1xPanel = initialTarget.pointsWide == panel.width && initialTarget.pointsHigh == panel.height
        modeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !self.stopped,
                      var m = CGDisplayCopyDisplayMode(id) else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                if now < settleUntil {
                    if m.width != initialTarget.pointsWide || m.height != initialTarget.pointsHigh ||
                       (initialTarget.pointsWide != self.panel.width &&
                        (m.pixelWidth != initialTarget.pixelsWide || m.pixelHeight != initialTarget.pixelsHigh)) {
                        correctedDuringSettle = true
                        self.selectNativeMode(id: id, pointsWide: initialTarget.pointsWide, pointsHigh: initialTarget.pointsHigh,
                                              pixelsWide: initialTarget.pixelsWide, pixelsHigh: initialTarget.pixelsHigh)
                    }
                    continue
                }
                if correctedDuringSettle {
                    correctedDuringSettle = false
                    if m.width == initialTarget.pointsWide, m.height == initialTarget.pointsHigh,
                       (m.pixelWidth != Int(lastPixels.width) || m.pixelHeight != Int(lastPixels.height)) {
                        lastSize = CGSize(width: m.width, height: m.height)
                        lastPixels = CGSize(width: m.pixelWidth, height: m.pixelHeight)
                        self.refreshDisplayState()
                        await self.rebuildStream(id: id, sourceWidth: m.pixelWidth, sourceHeight: m.pixelHeight)
                    }
                }
                if m.width == self.panel.width, m.height == self.panel.height, m.pixelWidth > self.panel.width {
                    if !tried1xPanel {
                        tried1xPanel = true
                        self.selectNativeMode(id: id, pointsWide: self.panel.width, pointsHigh: self.panel.height,
                                              pixelsWide: self.panel.width, pixelsHigh: self.panel.height)
                        if let updated = CGDisplayCopyDisplayMode(id) { m = updated }
                    }
                } else if m.width != self.panel.width || m.height != self.panel.height {
                    tried1xPanel = false
                }
                let size = CGSize(width: m.width, height: m.height)
                let pixels = CGSize(width: m.pixelWidth, height: m.pixelHeight)
                guard size.width > 0, size.height > 0, (size != lastSize || pixels != lastPixels) else { continue }
                lastSize = size
                lastPixels = pixels
                self.refreshDisplayState()
                await self.rebuildStream(id: id, sourceWidth: m.pixelWidth, sourceHeight: m.pixelHeight)
                let chosen = SavedDisplayMode(
                    pointsWide: m.width, pointsHigh: m.height,
                    pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight)
                DisplayModeDB.shared.save(for: self.panel, mode: chosen, allowedPointSizes: allowedPointSizes)
                SenderLog.info("Updated capture stream for scaled mode \(m.width)x\(m.height) (px=\(m.pixelWidth)x\(m.pixelHeight))")
            }
        }
    }

    @MainActor
    private func shareable(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<40 {
            let displays = try await SCShareableContent.current.displays
            if let match = displays.first(where: { $0.displayID == id && $0.width > 0 && $0.height > 0 }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SenderError("The virtual display did not appear in ScreenCaptureKit")
    }

    private func isUsingHardwareEncoder(_ session: VTCompressionSession) -> Bool {
        var dict: CFDictionary?
        guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &dict) == noErr else { return false }
        let out = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        out.initialize(to: nil)
        defer { out.deinitialize(count: 1); out.deallocate() }
        let status = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil,
            valueOut: out)
        guard status == noErr, let boolVal = out.pointee as? Bool else { return false }
        return boolVal
    }

    private func configureEncoder(width: Int, height: Int) throws {
        var created: VTCompressionSession?
        // Omit EnableLowLatencyRateControl: on Apple Silicon it causes
        // VideoToolbox to fall back to software encoding (~22 ms/frame) for H.264
        // and silently downgrades HEVC 4:4:4 to 4:2:0.
        let hwSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue
        ] as CFDictionary
        let bgraAttrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        if panel.codec == "hevc444" || panel.codec == "hevc" || panel.codec == "hevc420" {
            let want444 = panel.codec == "hevc444" || panel.codec == "hevc"
            let attrs: CFDictionary? = want444 ? bgraAttrs : nil
            var status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: hwSpec, imageBufferAttributes: attrs, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if created == nil {
                status = VTCompressionSessionCreate(
                    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                    encoderSpecification: nil, imageBufferAttributes: attrs, compressedDataAllocator: nil,
                    outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            }
            if status == noErr, let session = created {
                if want444 {
                    if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                            value: "HEVC_Main444_AutoLevel" as CFString) != noErr {
                        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
                    }
                } else {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                         value: kVTProfileLevel_HEVC_Main_AutoLevel)
                }
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: panel.fps as CFNumber)
                if want444 {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.94 as CFNumber)
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [16_000_000, 1.0] as CFArray)
                } else {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.95 as CFNumber)
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [16_000_000, 1.0] as CFArray)
                }
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
                if VTCompressionSessionPrepareToEncodeFrames(session) == noErr {
                    activeCodec = "hevc"
                    encoder = session
                    SenderLog.info("VideoToolbox encoder ready: negotiated=\(panel.codec), stream=\(activeCodec), hw=\(isUsingHardwareEncoder(session))")
                    return
                }
                VTCompressionSessionInvalidate(session)
                created = nil
            }
        }
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: hwSpec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if created == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else { throw SenderError("VideoToolbox encoder is unavailable") }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: panel.fps as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 60_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_Quality, value: 0.94 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits, value: [12_000_000, 1.0] as CFArray)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
            VTCompressionSessionInvalidate(created)
            throw SenderError("VideoToolbox could not prepare the encoder")
        }
        activeCodec = "h264"
        encoder = created
        SenderLog.info("VideoToolbox encoder ready: negotiated=\(panel.codec), stream=\(activeCodec), hw=\(isUsingHardwareEncoder(created))")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample), let image = CMSampleBufferGetImageBuffer(sample) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete && status != .started {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if submitFrame(image, pts: pts, forceAdmission: false, storeIfBusy: true) {
            refineTimer?.cancel()
            refineTimer = nil
        } else {
            scheduleRefinement()
        }
    }

    private func drainPendingFrame(forceAdmission: Bool) {
        lock.lock()
        guard !stopped, !encoding, let image = pendingImage else {
            lock.unlock()
            return
        }
        let pts = pendingPts.isValid ? pendingPts : CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()
        if submitFrame(image, pts: pts, forceAdmission: forceAdmission, storeIfBusy: false) {
            refineTimer?.cancel()
            refineTimer = nil
        } else {
            scheduleRefinement()
        }
    }

    private func scheduleRefinement() {
        refineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refineTimer?.cancel()
            self.refineTimer = nil
            self.drainPendingFrame(forceAdmission: true)
        }
        timer.resume()
        refineTimer = timer
    }

    private func scaledBuffer(_ image: CVImageBuffer) -> CVImageBuffer {
        let srcW = CVPixelBufferGetWidth(image), srcH = CVPixelBufferGetHeight(image)
        if srcW == panel.width && srcH == panel.height { return image }
        guard let ciContext else { return image }
        if scalePool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: panel.width,
                kCVPixelBufferHeightKey: panel.height,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &scalePool)
        }
        guard let pool = scalePool else { return image }
        var dstOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOpt) == kCVReturnSuccess, let dst = dstOpt else { return image }
        let isBGRA = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA
        let input = (isBGRA
            ? CIImage(cvPixelBuffer: image, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: image)
        ).clampedToExtent()
        guard let filter = CIFilter(name: "CIBicubicScaleTransform") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(Double(panel.width) / Double(max(1, srcW)), forKey: kCIInputScaleKey)
        filter.setValue((Double(panel.height) / Double(max(1, srcH))) / (Double(panel.width) / Double(max(1, srcW))), forKey: "inputAspectRatio")
        filter.setValue(1.0 / 3.0, forKey: "inputB")
        filter.setValue(1.0 / 3.0, forKey: "inputC")
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: panel.width, height: panel.height)) else {
            return image
        }
        ciContext.render(output, to: dst, bounds: CGRect(x: 0, y: 0, width: panel.width, height: panel.height),
                         colorSpace: isBGRA ? nil : srgbSpace)
        if let srgbSpace {
            CVBufferSetAttachment(dst, kCVImageBufferCGColorSpaceKey, srgbSpace, .shouldPropagate)
        }
        return dst
    }

    @discardableResult
    private func submitFrame(_ image: CVImageBuffer, pts: CMTime, forceAdmission: Bool, storeIfBusy: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        guard !encoding, transport.canAcceptVideo, let encoder,
              forceAdmission || now - lastSubmit >= 0.45 / Double(max(1, panel.fps)) else {
            if storeIfBusy {
                if pendingImage != nil {
                    framesDropped += 1
                }
                pendingImage = image
                pendingPts = pts
            }
            lock.unlock()
            return false
        }
        if storeIfBusy && pendingImage != nil {
            framesDropped += 1
        }
        pendingImage = nil
        pendingPts = .invalid
        encoding = true
        lastSubmit = now
        encodeStart = now
        let properties = needsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        needsKeyframe = false
        lock.unlock()
        let encodeImage = scaledBuffer(image)
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: encodeImage, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, output in self?.encoded(status: status, sample: output) }
        if status != noErr {
            SenderLog.info("Video encode submit failed: status=\(status)")
            finishEncode(failed: true)
        }
        return true
    }

    // A bad frame is skipped and the next frame is forced to a keyframe. Only a
    // run of consecutive failures ends the session, so a single oversized or
    // dropped frame never tears down the stream, and a persistent fault never
    // freezes the picture silently.
    private func frameFailed(_ detail: String) {
        lock.lock()
        consecutiveEncodeErrors += 1
        let count = consecutiveEncodeErrors
        lock.unlock()
        SenderLog.info("Video encode/frame error: \(detail) consecutive=\(count)")
        if count >= 3 {
            finishEncode(failed: true)
        } else {
            requestKeyframe()
            finishEncode(failed: false, skipped: true)
        }
    }

    private func encoded(status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample else {
            frameFailed("status=\(status) sample=\(sample == nil ? "nil" : "present")")
            return
        }
        guard let data = annexB(sample) else {
            let blockLen = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? -1
            frameFailed("annexB returned nil (blockBytes=\(blockLen), keyframe=\(isKeyframe(sample)))")
            return
        }
        do {
            if !(try transport.sendVideo(data)) {
                requestKeyframe()
                finishEncode(failed: false, skipped: true)
                return
            }
        } catch {
            frameFailed("sendVideo threw (\(error), bytes=\(data.count))")
            return
        }
        lock.lock()
        consecutiveEncodeErrors = 0
        lock.unlock()
        finishEncode(failed: false)
    }

    private func finishEncode(failed: Bool, skipped: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        var hasPending = false
        var ended = false
        var statsLine: String?
        lock.lock()
        encoding = false
        ended = stopped
        if skipped {
            framesDropped += 1
        } else if !failed {
            framesEncoded += 1
            totalEncodeMs += max(0.0, (now - encodeStart) * 1000.0)
            if logPeriodicStats {
                if lastStatsLog == 0.0 {
                    lastStatsLog = now
                } else if now - lastStatsLog >= 2.0 {
                    lastStatsLog = now
                    let avgMs = String(format: "%.1f", totalEncodeMs / Double(framesEncoded))
                    statsLine = "Session stats: frames=\(framesEncoded) dropped=\(framesDropped) avg_enc=\(avgMs)ms"
                }
            }
        }
        hasPending = !ended && !failed && pendingImage != nil
        lock.unlock()
        if let statsLine { SenderLog.info(statsLine) }
        if failed && !ended {
            transport.stop("Video encoder failed")
        } else if hasPending {
            sampleQueue.async { [weak self] in
                self?.drainPendingFrame(forceAdmission: true)
            }
        }
    }

    private func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var sets: [Data] = []
        if isKeyframe(sample), let format = CMSampleBufferGetFormatDescription(sample) {
            if activeCodec == "hevc" {
                var count = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, count >= 3 else { return nil }
                for index in 0..<count {
                    var set: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &set, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let set else { return nil }
                    sets.append(Data(bytes: set, count: size))
                }
            } else {
                for index in 0..<2 {
                    var set: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: &set, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let set else { return nil }
                    sets.append(Data(bytes: set, count: size))
                }
            }
        }
        return AnnexB.fromBlockBuffer(block, parameterSets: sets)
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    func requestKeyframe() { lock.lock(); needsKeyframe = true; lock.unlock() }
    func scrollPointScale() -> Double {
        lock.lock()
        let scale = cachedScrollScale
        lock.unlock()
        return scale
    }

    // Must be called on inputQueue.
    func handleInput(_ object: [String: Any]) throws {
        lock.lock()
        let ended = stopped
        let scale = cachedScrollScale
        lock.unlock()
        guard !ended, let input else { return }
        try input.handle(object, scrollScale: scale)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped, stream === self.stream else { return }
            SenderLog.info("Capture stream interrupted (\(error.localizedDescription)); recovering in place")
            await self.recoverStream()
        }
    }

    @MainActor
    func stop(_ reason: String) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        pendingImage = nil
        pendingPts = .invalid
        let encodedCount = framesEncoded
        let droppedCount = framesDropped
        let totalMs = totalEncodeMs
        lock.unlock()
        transport.onVideoDrained = nil
        modeTask?.cancel(); modeTask = nil
        sampleQueue.sync {
            self.refineTimer?.cancel()
            self.refineTimer = nil
        }
        if reconfigRegistered, let ctx = reconfigContext {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, ctx)
            reconfigRegistered = false
            reconfigContext = nil
        }
        inputQueue.sync {
            self.input?.cancel()
            self.input = nil
        }
        stream?.stopCapture { _ in }
        stream = nil
        if let encoder = encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        if let scalePool { CVPixelBufferPoolFlush(scalePool, .excessBuffers) }
        scalePool = nil
        display = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        if wakeAssertion != 0 {
            IOPMAssertionRelease(wakeAssertion)
            wakeAssertion = 0
        }
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        let avgMs = encodedCount > 0 ? String(format: "%.1f", totalMs / Double(encodedCount)) : "0.0"
        SenderLog.info("Session stats: frames=\(encodedCount) dropped=\(droppedCount) avg_enc=\(avgMs)ms")
        SenderLog.info(reason)
    }
}
