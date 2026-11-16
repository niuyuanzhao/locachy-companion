// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import VideoToolbox

enum SenderLog {
    static func info(_ text: String) { fputs("locachy-macos: \(text)\n", stderr) }
}

@available(macOS 14.0, *)
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let transport: SecureTransport
    private let panel: Panel
    private let sampleQueue = DispatchQueue(label: "locachy.macos.capture")
    private let lock = NSLock()
    private var display: VirtualDisplay?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var input: RemoteInput?
    private var refineTimer: DispatchSourceTimer?
    private var lastImage: CVImageBuffer?
    private var stopped = false
    private var needsKeyframe = true
    private var encoding = false
    private var lastSubmit = 0.0
    private var scrollScale = 1.0
    private var activeCodec = "h264"
    private var recovering = false
    private var sleepAssertion: IOPMAssertionID = 0

    init(transport: SecureTransport, panel: Panel) {
        self.transport = transport
        self.panel = panel
    }

    // Main actor: CGVirtualDisplay installs its WindowServer callbacks on main.
    @MainActor
    func start() async throws {
        try Task.checkCancellation()
        var wakeID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("LOCachy Extended Display" as CFString, kIOPMUserActiveLocal, &wakeID)
        _ = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "LOCachy Extended Display" as CFString,
            &sleepAssertion)
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard let plan = VirtualCanvasSizing.plan(pixelsWide: panel.width, pixelsHigh: panel.height, scale: panel.scale)
        else { throw SenderError("Receiver panel dimensions are unsupported") }
        let first = plan.bootstrap
        let millimeters = first.pointsWide >= first.pointsHigh ? CGSize(width: 300, height: 190) : CGSize(width: 190, height: 300)
        var createdDisplay: VirtualDisplay?
        for probe: UInt32 in 0..<8 {
            if let candidate = VirtualDisplay(
                name: "LOCachy", pointsWide: first.pointsWide, pointsHigh: first.pointsHigh,
                scale: first.scale, descriptorMaxPixelsPerAxis: plan.descriptorMaxPixelsPerAxis,
                sizeInMillimeters: millimeters, serialNum: 0x4C4F4301 + probe, productID: 0x4C4F + probe
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
                                           scale: plan.requested.scale, movingTo: nil) else {
                    throw SenderError("macOS rejected the receiver resolution")
                }
            }
            for _ in 0..<20 {
                selectNativeMode(id: id, pointsWide: plan.requested.pointsWide, pointsHigh: plan.requested.pointsHigh,
                                 pixelsWide: plan.requested.pixelsWide, pixelsHigh: plan.requested.pixelsHigh)
                if let cur = CGDisplayCopyDisplayMode(id),
                   cur.width == plan.requested.pointsWide, cur.height == plan.requested.pointsHigh,
                   cur.pixelWidth == plan.requested.pixelsWide, cur.pixelHeight == plan.requested.pixelsHigh {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard CGDisplayIsInMirrorSet(id) != 1 else { throw SenderError("macOS placed the LOCachy display in a mirror set") }
            let width = CGDisplayPixelsWide(id), height = CGDisplayPixelsHigh(id)
            guard width == plan.requested.pixelsWide, height == plan.requested.pixelsHigh else {
                throw SenderError("Virtual display did not enter the requested 1:1 mode")
            }
            let target = try await shareable(id)
            try Task.checkCancellation()
            try configureEncoder(width: width, height: height)
            input = RemoteInput(displayID: id)
            let filter = SCContentFilter(display: target, excludingWindows: [])
            let configuration = makeStreamConfiguration(width: width, height: height)
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            stream = capture
            transport.sendObject(["type": "streamConfig", "codec": activeCodec, "width": width,
                                  "height": height, "framesPerSecond": panel.fps])
            try await capture.startCapture()
            try Task.checkCancellation()
            SenderLog.info("Extended display \(id) is active at \(plan.requested.pointsWide)x\(plan.requested.pointsHigh) @\(plan.requested.scale)x (\(width)x\(height), \(activeCodec))")
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
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
    private func rebuildStream(id: CGDirectDisplayID) async {
        guard !stopped, !recovering else { return }
        recovering = true
        defer { recovering = false }
        try? await Task.sleep(for: .milliseconds(60))
        guard !stopped, let updated = try? await shareable(id) else { return }
        guard !stopped else { return }
        let cfg = makeStreamConfiguration(width: panel.width, height: panel.height)
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
        await rebuildStream(id: display.displayID)
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

    private func configureEncoder(width: Int, height: Int) throws {
        var created: VTCompressionSession?
        let hwSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue
        ] as CFDictionary
        let bgraAttrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        if panel.codec == "hevc" {
            // EnableLowLatencyRateControl silently downgrades HEVC_Main444_AutoLevel to 4:2:0 on Apple Silicon.
            // RequireHardwareAcceleratedVideoEncoder + RealTime + MaxFrameDelayCount=0 keeps true 4:4:4 at ~8.8ms/frame.
            var status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: hwSpec, imageBufferAttributes: bgraAttrs, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if created == nil {
                status = VTCompressionSessionCreate(
                    allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
                    encoderSpecification: nil, imageBufferAttributes: bgraAttrs, compressedDataAllocator: nil,
                    outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            }
            if status == noErr, let session = created {
                if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                        value: "HEVC_Main444_AutoLevel" as CFString) != noErr {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                         value: kVTProfileLevel_HEVC_Main_AutoLevel)
                }
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: panel.fps as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.92 as CFNumber)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [15_000_000, 1.0] as CFArray)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                if VTCompressionSessionPrepareToEncodeFrames(session) == noErr {
                    activeCodec = "hevc"
                    encoder = session
                    return
                }
                VTCompressionSessionInvalidate(session)
                created = nil
            }
        }
        let h264Spec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: h264Spec, imageBufferAttributes: bgraAttrs, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if created == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: bgraAttrs, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else { throw SenderError("VideoToolbox encoder is unavailable") }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: panel.fps as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 45_000_000 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits, value: [10_000_000, 1] as CFArray)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        guard VTCompressionSessionPrepareToEncodeFrames(created) == noErr else {
            VTCompressionSessionInvalidate(created)
            throw SenderError("VideoToolbox could not prepare the encoder")
        }
        activeCodec = "h264"
        encoder = created
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sample), let image = CMSampleBufferGetImageBuffer(sample) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete && status != .started {
            return
        }
        if submitFrame(image, pts: CMSampleBufferGetPresentationTimeStamp(sample), forceAdmission: false) {
            refineTimer?.cancel()
            refineTimer = nil
            lock.lock()
            lastImage = nil
            lock.unlock()
        } else {
            lock.lock()
            lastImage = image
            lock.unlock()
            scheduleRefinement()
        }
    }

    private func scheduleRefinement() {
        refineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let image = self.lastImage
            let ended = self.stopped
            self.lock.unlock()
            self.refineTimer?.cancel()
            self.refineTimer = nil
            guard !ended, let image else { return }
            if self.submitFrame(image, pts: CMClockGetTime(CMClockGetHostTimeClock()), forceAdmission: true) {
                self.lock.lock()
                self.lastImage = nil
                self.lock.unlock()
            } else {
                self.scheduleRefinement()
            }
        }
        timer.resume()
        refineTimer = timer
    }

    @discardableResult
    private func submitFrame(_ image: CVImageBuffer, pts: CMTime, forceAdmission: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped, !encoding, transport.canAcceptVideo, let encoder,
              forceAdmission || now - lastSubmit >= 0.80 / Double(panel.fps) else { lock.unlock(); return false }
        encoding = true
        lastSubmit = now
        let properties = needsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        needsKeyframe = false
        lock.unlock()
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, output in self?.encoded(status: status, sample: output) }
        if status != noErr { finishEncode(failed: true) }
        return true
    }

    private func encoded(status: OSStatus, sample: CMSampleBuffer?) {
        guard status == noErr, let sample, let data = annexB(sample) else { finishEncode(failed: true); return }
        do { try transport.sendVideo(data); finishEncode(failed: false) }
        catch { finishEncode(failed: true) }
    }

    private func finishEncode(failed: Bool) {
        lock.lock(); encoding = false; let ended = stopped; lock.unlock()
        if failed && !ended { transport.stop("Video encoder failed") }
    }

    private func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return nil }
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
        return AnnexB.fromAVCC(UnsafeRawBufferPointer(start: pointer, count: total), parameterSets: sets)
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    func requestKeyframe() { lock.lock(); needsKeyframe = true; lock.unlock() }
    func scrollPointScale() -> Double {
        guard let display else { return 1.0 }
        let bounds = CGDisplayBounds(display.displayID)
        return bounds.width > 0 ? bounds.width / Double(max(1, panel.width)) : 1.0
    }

    @MainActor
    func handleInput(_ object: [String: Any]) throws {
        guard let input else { return }
        try input.handle(object, scrollScale: scrollPointScale())
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
        lastImage = nil
        lock.unlock()
        refineTimer?.cancel(); refineTimer = nil
        input?.cancel()
        input = nil
        stream?.stopCapture { _ in }
        stream = nil
        if let encoder = encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        display = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        SenderLog.info(reason)
    }
}
