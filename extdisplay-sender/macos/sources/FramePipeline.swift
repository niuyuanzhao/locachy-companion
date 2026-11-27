// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

enum FrameAdmission: Equatable {
    case admit
    case busy
    case paced(delay: TimeInterval)
}

// Bounds VideoToolbox encode concurrency (2 frames in flight) and post-encode
// packetization/send handoff while preserving frame pacing without stalling on
// fixed 16 ms retries when a frame arrives just inside the minimum interval.
struct FramePacer {
    static let maxInFlightEncodes = 2
    static let maxInFlightSends = 2
    static let busyFallbackDelay: TimeInterval = 0.016
    static let minimumPacedDelay: TimeInterval = 0.001

    let minInterval: TimeInterval
    private(set) var inFlightEncodes = 0
    private(set) var inFlightSends = 0
    private(set) var lastSubmit: TimeInterval = 0.0
    private(set) var hasSubmitted = false

    init(fps: Int) {
        self.minInterval = 0.45 / Double(max(1, fps))
    }

    mutating func tryAdmit(now: TimeInterval, transportCanAccept: Bool, forceAdmission: Bool) -> FrameAdmission {
        guard inFlightEncodes < Self.maxInFlightEncodes,
              inFlightSends < Self.maxInFlightSends,
              transportCanAccept else {
            return .busy
        }
        if !forceAdmission && hasSubmitted {
            let elapsed = now - lastSubmit
            if elapsed < minInterval {
                let remaining = min(minInterval, max(Self.minimumPacedDelay, minInterval - elapsed))
                return .paced(delay: remaining)
            }
        }
        inFlightEncodes += 1
        lastSubmit = now
        hasSubmitted = true
        return .admit
    }

    mutating func finishEncode(handoffToSend: Bool) {
        inFlightEncodes = max(0, inFlightEncodes - 1)
        if handoffToSend {
            inFlightSends += 1
        }
    }

    mutating func finishSend() {
        inFlightSends = max(0, inFlightSends - 1)
    }
}

// GPU BGRA scaler backed by Apple's MetalPerformanceShaders
// (MPSImageLanczosScale) operating directly on IOSurface-backed CVPixelBuffers
// through CVMetalTextureCache with zero custom shaders.
final class MetalImageScaler {
    private struct Dimensions: Equatable {
        let srcW: Int
        let srcH: Int
        let dstW: Int
        let dstH: Int
    }

    private static let srcTextureAttrs: CFDictionary = [
        kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
    ] as CFDictionary
    private static let dstTextureAttrs: CFDictionary = [
        kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue)
    ] as CFDictionary

    private let lock = NSLock()
    private let commandQueue: MTLCommandQueue
    private let lanczos: MPSImageLanczosScale
    private let textureCache: CVMetalTextureCache
    private var lastDims: Dimensions?
    private var scaleCount: UInt64 = 0

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              MPSSupportsMTLDevice(device),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        var cacheOpt: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOpt) == kCVReturnSuccess,
              let textureCache = cacheOpt else {
            return nil
        }
        let lanczos = MPSImageLanczosScale(device: device)
        lanczos.edgeMode = .clamp
        self.commandQueue = commandQueue
        self.lanczos = lanczos
        self.textureCache = textureCache
    }

    func scale(from src: CVPixelBuffer, to dst: CVPixelBuffer) -> Bool {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let dstW = CVPixelBufferGetWidth(dst)
        let dstH = CVPixelBufferGetHeight(dst)
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0,
              CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(dst) == kCVPixelFormatType_32BGRA else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        let dims = Dimensions(srcW: srcW, srcH: srcH, dstW: dstW, dstH: dstH)
        if lastDims != dims {
            CVMetalTextureCacheFlush(textureCache, 0)
            let transform = MPSScaleTransform(
                scaleX: Double(dstW) / Double(srcW),
                scaleY: Double(dstH) / Double(srcH),
                translateX: 0.0,
                translateY: 0.0
            )
            withUnsafePointer(to: transform) {
                lanczos.scaleTransform = $0
            }
            lastDims = dims
        }

        var srcMetalOpt: CVMetalTexture?
        let srcStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, src, Self.srcTextureAttrs,
            .bgra8Unorm, srcW, srcH, 0, &srcMetalOpt
        )
        var dstMetalOpt: CVMetalTexture?
        let dstStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, dst, Self.dstTextureAttrs,
            .bgra8Unorm, dstW, dstH, 0, &dstMetalOpt
        )
        guard srcStatus == kCVReturnSuccess,
              dstStatus == kCVReturnSuccess,
              let srcMetal = srcMetalOpt,
              let dstMetal = dstMetalOpt,
              let srcTex = CVMetalTextureGetTexture(srcMetal),
              let dstTex = CVMetalTextureGetTexture(dstMetal),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        lanczos.encode(commandBuffer: commandBuffer, sourceTexture: srcTex, destinationTexture: dstTex)

        let ok: Bool = withExtendedLifetime((srcMetal, dstMetal)) {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return commandBuffer.status == .completed
        }

        scaleCount &+= 1
        if scaleCount % 120 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return ok
    }

    func flush() {
        lock.lock()
        lastDims = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        lock.unlock()
    }
}
