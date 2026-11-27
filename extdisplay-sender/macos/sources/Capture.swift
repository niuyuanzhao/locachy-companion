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

// Serializes WindowServer virtual-display creation and display configuration
// transactions across concurrent sessions so two simultaneous connects never
// interleave CGBeginDisplayConfiguration / CGCompleteDisplayConfiguration.
@MainActor
private final class DisplaySetupGate {
    static let shared = DisplaySetupGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            }
        }
        return try await operation()
    }

    func run<T>(_ operation: @MainActor () async -> T) async -> T {
        while busy {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            }
        }
        return await operation()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class VirtualDisplayCoordinator {
    static let shared = VirtualDisplayCoordinator()
    private var policy = VirtualDisplayResetPolicy()
    private var sessions: [ObjectIdentifier: CaptureSession] = [:]

    func register(_ session: CaptureSession) {
        let token = ObjectIdentifier(session)
        sessions[token] = session
        policy.recordAttach(token)
    }

    func unregister(_ session: CaptureSession) {
        let token = ObjectIdentifier(session)
        sessions.removeValue(forKey: token)
        policy.recordDetach(token)
    }

    // Must be called while holding DisplaySetupGate.shared. Runs inside an
    // uncancelled MainActor task so cancellation of the newly arriving session
    // never leaves existing live sessions half-suspended.
    func suspendAllIfNeeded() async -> [CaptureSession] {
        guard policy.shouldResetBeforeAttach else { return [] }
        let live = Array(sessions.values).filter { !$0.isStopped }
        guard !live.isEmpty else {
            policy.recordResetDrained()
            return []
        }
        return await Task { @MainActor in
            SenderLog.info("Resetting \(live.count) active virtual display(s) before attaching another to avoid ScreenCaptureKit stream confusion (FB17797423)")
            var suspendedIDs: [CGDirectDisplayID] = []
            for session in live {
                if let oldID = await session.suspendForReset() {
                    suspendedIDs.append(oldID)
                }
                self.sessions.removeValue(forKey: ObjectIdentifier(session))
            }
            self.policy.recordResetDrained()
            await Self.waitUntilOffline(suspendedIDs)
            try? await Task.sleep(for: .milliseconds(150))
            return live.filter { !$0.isStopped }
        }.value
    }

    private static func waitUntilOffline(_ targets: [CGDirectDisplayID]) async {
        guard !targets.isEmpty else { return }
        let targetSet = Set(targets)
        for _ in 0..<30 {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var online = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if count > 0 {
                CGGetOnlineDisplayList(count, &online, &count)
            }
            if targetSet.isDisjoint(with: online.prefix(Int(count))) {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

@available(macOS 14.0, *)
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let transport: SecureTransport
    private let panel: Panel
    private let hostIDOverride: String?
    private let inputCoordinator: InputCoordinator
    private let sampleQueue = DispatchQueue(label: "locachy.macos.capture", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "locachy.macos.send", qos: .userInteractive)
    let inputQueue: DispatchQueue
    private let lock = NSLock()
    private var display: VirtualDisplay?
    private var claimedSerialNum: UInt32?
    private var displayPlan: VirtualCanvasPlan?
    private var allowedModes: [CGVirtualDisplayMode] = []
    private var allowedPointSizes: [(Int, Int)] = []
    private var displayMillimeters: CGSize = .zero
    private var preferredIdentity: VirtualDisplayIdentity?
    private var lastActiveMode: SavedDisplayMode?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var input: RemoteInput?
    private var modeTask: Task<Void, Never>?
    private var capsSyncNegotiated: Bool { panel.supportedInput.contains("capsLock") }
    private var refineTimer: DispatchSourceTimer?
    private var pendingImage: CVImageBuffer?
    private var pendingPts: CMTime = .invalid
    private var stopped = false
    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    private var needsKeyframe = true
    private var pacer: FramePacer
    private var cachedScrollScale = 1.0
    private var framesEncoded: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var totalEncodeMs = 0.0
    private var lastStatsLog = 0.0
    private let logPeriodicStats = ProcessInfo.processInfo.environment["LOCACHY_STATS"] == "1"
    private var activeCodec = "h264"
    private var recovering = false
    private var resetting = false
    private var captureWidth = 0
    private var captureHeight = 0
    private var sleepAssertion: IOPMAssertionID = 0
    private var wakeAssertion: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?
    private var consecutiveEncodeErrors = 0
    private var reconfigRegistered = false
    private var reconfigContext: UnsafeMutableRawPointer?
    private var metalScaler: MetalImageScaler?
    private var metalScalerInitialized = false
    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        }
        return CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }()
    private var scalePool: CVPixelBufferPool?
    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init(transport: SecureTransport, panel: Panel,
         hostIDOverride: String? = nil,
         inputCoordinator: InputCoordinator = .shared,
         inputQueue: DispatchQueue? = nil) {
        self.transport = transport
        self.panel = panel
        self.pacer = FramePacer(fps: panel.fps)
        self.hostIDOverride = hostIDOverride
        self.inputCoordinator = inputCoordinator
        self.inputQueue = inputQueue ?? inputCoordinator.queue
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

    @MainActor
    private func createAndConfigureVirtualDisplay(
        plan: VirtualCanvasPlan,
        allowedModes: [CGVirtualDisplayMode],
        allowedPointSizes: [(Int, Int)],
        millimeters: CGSize,
        preferredIdentity: VirtualDisplayIdentity,
        preferredModeOverride: SavedDisplayMode?,
        checkCancellation: Bool
    ) async throws -> (CGDirectDisplayID, SavedDisplayMode) {
        let first = plan.bootstrap
        let initialModes: [CGVirtualDisplayMode]? = (plan.requested == first) ? allowedModes : nil
        let claimed = ActiveDisplayRegistry.shared.claim(preferred: preferredIdentity)
        claimedSerialNum = claimed.serialNum
        do {
            if checkCancellation { try Task.checkCancellation() }
            var createdDisplay: VirtualDisplay?
            var activeSerial = claimed.serialNum
            for probe: UInt32 in 0..<8 {
                if checkCancellation { try Task.checkCancellation() }
                let probeSerial: UInt32
                let probeProduct: UInt32
                if probe == 0 {
                    probeSerial = claimed.serialNum
                    probeProduct = claimed.productID
                } else {
                    let bumped = ActiveDisplayRegistry.shared.claim(
                        preferred: VirtualDisplayIdentity(
                            name: claimed.name,
                            serialNum: ((claimed.serialNum &+ probe) & 0x7FFF_FFFF) == 0 ? 1 : ((claimed.serialNum &+ probe) & 0x7FFF_FFFF),
                            productID: 0x4C00 | ((claimed.productID &+ probe) & 0x00FF)
                        )
                    )
                    ActiveDisplayRegistry.shared.release(serialNum: activeSerial)
                    activeSerial = bumped.serialNum
                    self.claimedSerialNum = activeSerial
                    probeSerial = bumped.serialNum
                    probeProduct = bumped.productID
                }
                if let candidate = VirtualDisplay(
                    name: claimed.name, pointsWide: first.pointsWide, pointsHigh: first.pointsHigh,
                    scale: first.scale, descriptorMaxPixelsPerAxis: plan.descriptorMaxPixelsPerAxis,
                    sizeInMillimeters: millimeters, serialNum: probeSerial, productID: probeProduct,
                    modes: initialModes
                ) {
                    createdDisplay = candidate
                    break
                }
                if checkCancellation {
                    try await Task.sleep(for: .milliseconds(100))
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard let created = createdDisplay else {
                throw SenderError("CGVirtualDisplay is unavailable or rejected this mode")
            }
            self.display = created
            let displayID = created.displayID
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
            var targetMode = preferredModeOverride
                ?? DisplayModeDB.shared.lookup(for: panel, allowedPointSizes: allowedPointSizes)
                ?? defaultTarget
            for _ in 0..<20 {
                if checkCancellation { try Task.checkCancellation() }
                self.selectNativeMode(id: displayID, pointsWide: targetMode.pointsWide, pointsHigh: targetMode.pointsHigh,
                                      pixelsWide: targetMode.pixelsWide, pixelsHigh: targetMode.pixelsHigh)
                if let cur = CGDisplayCopyDisplayMode(displayID),
                   cur.width == targetMode.pointsWide, cur.height == targetMode.pointsHigh,
                   (cur.pixelWidth == targetMode.pixelsWide && cur.pixelHeight == targetMode.pixelsHigh
                    || targetMode.pointsWide == panel.width) {
                    break
                }
                if checkCancellation {
                    try await Task.sleep(for: .milliseconds(50))
                } else {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            if let cur = CGDisplayCopyDisplayMode(displayID),
               cur.width != targetMode.pointsWide || cur.height != targetMode.pointsHigh,
               targetMode != defaultTarget {
                targetMode = defaultTarget
                for _ in 0..<20 {
                    if checkCancellation { try Task.checkCancellation() }
                    self.selectNativeMode(id: displayID, pointsWide: targetMode.pointsWide, pointsHigh: targetMode.pointsHigh,
                                          pixelsWide: targetMode.pixelsWide, pixelsHigh: targetMode.pixelsHigh)
                    if let updated = CGDisplayCopyDisplayMode(displayID),
                       updated.width == targetMode.pointsWide, updated.height == targetMode.pointsHigh {
                        break
                    }
                    if checkCancellation {
                        try await Task.sleep(for: .milliseconds(50))
                    } else {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            guard CGDisplayIsInMirrorSet(displayID) != 1 else {
                throw SenderError("macOS placed the LOCachy display in a mirror set")
            }
            guard let cur = CGDisplayCopyDisplayMode(displayID),
                  cur.width > 0, cur.height > 0, cur.pixelWidth > 0, cur.pixelHeight > 0 else {
                throw SenderError("Virtual display did not enter the requested display mode")
            }
            if cur.width != targetMode.pointsWide || cur.height != targetMode.pointsHigh {
                // Accept another valid mode from our advertised list instead of
                // discarding the virtual display and thrashing WindowServer.
                guard allowedPointSizes.contains(where: { $0.0 == cur.width && $0.1 == cur.height }) else {
                    throw SenderError("Virtual display did not enter the requested display mode")
                }
                SenderLog.info("Virtual display \(displayID) settled at \(cur.width)x\(cur.height) (px=\(cur.pixelWidth)x\(cur.pixelHeight)) instead of \(targetMode.pointsWide)x\(targetMode.pointsHigh); proceeding")
            }
            return (displayID, SavedDisplayMode(
                pointsWide: cur.width, pointsHigh: cur.height,
                pixelsWide: cur.pixelWidth, pixelsHigh: cur.pixelHeight))
        } catch {
            // Release the partially configured virtual display and serial inside
            // DisplaySetupGate so WindowServer never overlaps teardown with a retry.
            self.display = nil
            if let serial = self.claimedSerialNum {
                ActiveDisplayRegistry.shared.release(serialNum: serial)
                self.claimedSerialNum = nil
            }
            throw error
        }
    }

    @MainActor
    func suspendForReset() async -> CGDirectDisplayID? {
        guard !isStopped else { return nil }
        resetting = true
        let oldID = display?.displayID
        if let oldID, let cur = CGDisplayCopyDisplayMode(oldID),
           cur.width > 0, cur.height > 0, cur.pixelWidth > 0, cur.pixelHeight > 0 {
            lastActiveMode = SavedDisplayMode(
                pointsWide: cur.width, pointsHigh: cur.height,
                pixelsWide: cur.pixelWidth, pixelsHigh: cur.pixelHeight
            )
        }
        modeTask?.cancel(); modeTask = nil
        if reconfigRegistered, let ctx = reconfigContext {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, ctx)
            reconfigRegistered = false
            reconfigContext = nil
        }
        if let activeStream = stream {
            stream = nil
            try? activeStream.removeStreamOutput(self, type: .screen)
            try? await activeStream.stopCapture()
        }
        sampleQueue.sync {
            self.refineTimer?.cancel()
            self.refineTimer = nil
        }
        lock.withLock {
            pendingImage = nil
            pendingPts = .invalid
        }
        display = nil
        if let serial = claimedSerialNum {
            ActiveDisplayRegistry.shared.release(serialNum: serial)
            claimedSerialNum = nil
        }
        return oldID
    }

    @MainActor
    func recreateDisplayForReset() async -> (CGDirectDisplayID, SavedDisplayMode)? {
        guard !isStopped,
              let plan = displayPlan,
              let preferred = preferredIdentity else {
            resetting = false
            return nil
        }
        do {
            let (id, mode) = try await createAndConfigureVirtualDisplay(
                plan: plan,
                allowedModes: allowedModes,
                allowedPointSizes: allowedPointSizes,
                millimeters: displayMillimeters,
                preferredIdentity: preferred,
                preferredModeOverride: lastActiveMode,
                checkCancellation: false
            )
            if isStopped {
                display = nil
                if let serial = claimedSerialNum {
                    ActiveDisplayRegistry.shared.release(serialNum: serial)
                    claimedSerialNum = nil
                }
                resetting = false
                return nil
            }
            lastActiveMode = mode
            VirtualDisplayCoordinator.shared.register(self)
            return (id, mode)
        } catch {
            resetting = false
            if !isStopped {
                SenderLog.info("Virtual display reset failed for \(preferred.name): \(error)")
                transport.stop("Virtual display reset failed: \(error)")
            }
            return nil
        }
    }

    @MainActor
    func restartCaptureAfterReset(id: CGDirectDisplayID, activeMode: SavedDisplayMode) async {
        defer { resetting = false }
        guard !isStopped else {
            display = nil
            if let serial = claimedSerialNum {
                ActiveDisplayRegistry.shared.release(serialNum: serial)
                claimedSerialNum = nil
            }
            VirtualDisplayCoordinator.shared.unregister(self)
            return
        }
        do {
            let capW = activeMode.pixelsWide, capH = activeMode.pixelsHigh
            captureWidth = capW
            captureHeight = capH
            let target = try await shareable(id, checkCancellation: false)
            guard !isStopped else { return }
            updateScrollScale(displayID: id)
            inputQueue.sync { self.input?.updateDisplayID(id) }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            if !reconfigRegistered,
               CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, ctx) == .success {
                reconfigContext = ctx
                reconfigRegistered = true
            }
            let filter = SCContentFilter(display: target, excludingWindows: [])
            let configuration = makeStreamConfiguration(width: capW, height: capH)
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            stream = capture
            requestKeyframe()
            try await capture.startCapture()
            guard !isStopped else {
                stream = nil
                try? capture.removeStreamOutput(self, type: .screen)
                try? await capture.stopCapture()
                return
            }
            startModeWatcher(id: id, initialTarget: activeMode, allowedPointSizes: allowedPointSizes)
            let serialHex = String(format: "0x%08x", claimedSerialNum ?? preferredIdentity?.serialNum ?? 0)
            SenderLog.info("Extended display \(id) (\(preferredIdentity?.name ?? panel.displayLabel), serial=\(serialHex)) resumed after virtual-display reset at \(activeMode.pointsWide)x\(activeMode.pointsHigh) (cap=\(capW)x\(capH))")
        } catch {
            if !isStopped {
                SenderLog.info("Capture restart after virtual-display reset failed: \(error)")
                transport.stop("Capture restart after virtual-display reset failed: \(error)")
            }
        }
    }

    // Main actor: CGVirtualDisplay installs its WindowServer callbacks on main.
    @MainActor
    func start() async throws {
        try Task.checkCancellation()
        do {
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
            let modes = VirtualDisplay.scaledModes(
                panelWide: panel.width, panelHigh: panel.height,
                scale: plan.requested.scale, maxPixelsPerAxis: plan.descriptorMaxPixelsPerAxis)
            let pointSizes = modes.map { (Int($0.width), Int($0.height)) }
            let millimeters = VirtualDisplay.syntheticMillimeters(for: modes)
            let preferred = VirtualDisplayIdentity.derive(from: panel, hostIDOverride: hostIDOverride)
            self.displayPlan = plan
            self.allowedModes = modes
            self.allowedPointSizes = pointSizes
            self.displayMillimeters = millimeters
            self.preferredIdentity = preferred

            let (id, activeMode): (CGDirectDisplayID, SavedDisplayMode) = try await DisplaySetupGate.shared.withLock {
                // If another virtual display is already active, drain all virtual
                // displays to zero and recreate every CGVirtualDisplay before
                // starting any SCStream so ScreenCaptureKit maps each stream to
                // its own framebuffer (FB17797423).
                let suspended = await VirtualDisplayCoordinator.shared.suspendAllIfNeeded()
                let recreated: [(CaptureSession, CGDirectDisplayID, SavedDisplayMode)] = await Task { @MainActor in
                    var out: [(CaptureSession, CGDirectDisplayID, SavedDisplayMode)] = []
                    for session in suspended {
                        if let pair = await session.recreateDisplayForReset() {
                            out.append((session, pair.0, pair.1))
                        }
                    }
                    return out
                }.value

                func resumeRecreated() async {
                    guard !recreated.isEmpty else { return }
                    await Task { @MainActor in
                        for (session, resumedID, resumedMode) in recreated {
                            await session.restartCaptureAfterReset(id: resumedID, activeMode: resumedMode)
                        }
                    }.value
                }

                let ownID: CGDirectDisplayID
                let ownMode: SavedDisplayMode
                do {
                    try Task.checkCancellation()
                    let pair = try await self.createAndConfigureVirtualDisplay(
                        plan: plan,
                        allowedModes: modes,
                        allowedPointSizes: pointSizes,
                        millimeters: millimeters,
                        preferredIdentity: preferred,
                        preferredModeOverride: nil,
                        checkCancellation: true
                    )
                    ownID = pair.0
                    ownMode = pair.1
                    self.lastActiveMode = ownMode
                    VirtualDisplayCoordinator.shared.register(self)
                } catch {
                    await resumeRecreated()
                    throw error
                }

                // All CGVirtualDisplays are now attached; start all SCStreams.
                await resumeRecreated()

                do {
                    let width = self.panel.width, height = self.panel.height
                    let capW = ownMode.pixelsWide, capH = ownMode.pixelsHigh
                    self.captureWidth = capW
                    self.captureHeight = capH
                    let target = try await self.shareable(ownID)
                    try Task.checkCancellation()
                    try self.configureEncoder(width: width, height: height)
                    self.updateScrollScale(displayID: ownID)
                    let remoteInput = RemoteInput(
                        displayID: ownID,
                        coordinator: self.inputCoordinator,
                        capsSyncNegotiated: self.capsSyncNegotiated
                    )
                    self.inputQueue.sync { self.input = remoteInput }
                    let ctx = Unmanaged.passUnretained(self).toOpaque()
                    if CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, ctx) == .success {
                        self.reconfigContext = ctx
                        self.reconfigRegistered = true
                    }
                    self.transport.onVideoDrained = { [weak self] in
                        self?.sampleQueue.async { [weak self] in
                            self?.drainPendingFrame(forceAdmission: false)
                        }
                    }
                    let filter = SCContentFilter(display: target, excludingWindows: [])
                    let configuration = self.makeStreamConfiguration(width: capW, height: capH)
                    let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
                    try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                    self.stream = capture
                    // Snapshot first: the receiver accepts capsLockState right after welcome, and
                    // every later Mac change is broadcast through the same ordered transport.
                    if self.capsSyncNegotiated {
                        self.inputCoordinator.registerCapsLockSubscriber(sessionID: remoteInput.sessionID) { [weak self] state in
                            self?.transport.sendObject(["type": "capsLockState", Wire.capsLockStateField: state])
                        }
                    }
                    self.transport.sendObject(["type": "streamConfig", "codec": self.activeCodec, "width": width,
                                               "height": height, "framesPerSecond": self.panel.fps])
                    try await capture.startCapture()
                    try Task.checkCancellation()
                    return (ownID, ownMode)
                } catch {
                    if let activeStream = self.stream {
                        self.stream = nil
                        try? activeStream.removeStreamOutput(self, type: .screen)
                        try? await activeStream.stopCapture()
                    }
                    self.display = nil
                    if let serial = self.claimedSerialNum {
                        ActiveDisplayRegistry.shared.release(serialNum: serial)
                        self.claimedSerialNum = nil
                    }
                    VirtualDisplayCoordinator.shared.unregister(self)
                    throw error
                }
            }
            startModeWatcher(id: id, initialTarget: activeMode, allowedPointSizes: pointSizes)
            let serialHex = String(format: "0x%08x", claimedSerialNum ?? preferred.serialNum)
            SenderLog.info("Extended display \(id) (\(preferred.name), serial=\(serialHex)) is active at \(activeMode.pointsWide)x\(activeMode.pointsHigh) (cap=\(activeMode.pixelsWide)x\(activeMode.pixelsHigh), out=\(panel.width)x\(panel.height), \(activeCodec), \(panel.identityKey))")
        } catch {
            await stopAsync("Capture setup failed: \(error)")
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
            // MPS GPU scaling runs in RGB before 4:2:0 encoding.
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

    private enum RebuildResult {
        case succeeded
        case skipped
        case failed(Error)
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamError.errorDomain && ns.code == SCStreamError.userDeclined.rawValue
    }

    @MainActor
    private func rebuildStream(id: CGDirectDisplayID, sourceWidth: Int, sourceHeight: Int) async -> RebuildResult {
        guard !stopped, !recovering, !resetting else { return .skipped }
        recovering = true
        defer { recovering = false }
        try? await Task.sleep(for: .milliseconds(60))
        guard !stopped, !resetting else { return .skipped }
        let updated: SCDisplay
        do {
            updated = try await shareable(id)
        } catch {
            return (stopped || resetting) ? .skipped : .failed(error)
        }
        guard !stopped, !resetting else { return .skipped }
        captureWidth = sourceWidth
        captureHeight = sourceHeight
        let cfg = makeStreamConfiguration(width: sourceWidth, height: sourceHeight)
        let filter = SCContentFilter(display: updated, excludingWindows: [])
        if let active = stream {
            do {
                try await active.updateContentFilter(filter)
                try await active.updateConfiguration(cfg)
                requestKeyframe()
                return (stopped || resetting) ? .skipped : .succeeded
            } catch {
                // Fall through to full SCStream replacement if in-place update fails.
            }
        }
        guard !stopped, !resetting else { return .skipped }
        let oldStream = stream
        let replacement = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            stream = replacement
            requestKeyframe()
            try await replacement.startCapture()
            if stopped || resetting {
                try? replacement.removeStreamOutput(self, type: .screen)
                try? await replacement.stopCapture()
                if let oldStream, oldStream !== replacement {
                    try? oldStream.removeStreamOutput(self, type: .screen)
                    try? await oldStream.stopCapture()
                }
                if stream === replacement { stream = nil }
                return .skipped
            }
            if let oldStream, oldStream !== replacement {
                try? oldStream.removeStreamOutput(self, type: .screen)
                try? await oldStream.stopCapture()
            }
            return .succeeded
        } catch {
            if stopped || resetting {
                if let oldStream, oldStream !== replacement {
                    try? oldStream.removeStreamOutput(self, type: .screen)
                    try? await oldStream.stopCapture()
                }
                if stream === replacement { stream = nil }
                return .skipped
            } else if stream === replacement {
                stream = oldStream
            }
            return .failed(error)
        }
    }

    @MainActor
    private func recoverStream() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard !stopped, !resetting, let display else { return }
        let m = CGDisplayCopyDisplayMode(display.displayID)
        if case .failed(let error) = await rebuildStream(id: display.displayID,
                                                         sourceWidth: m?.pixelWidth ?? panel.width,
                                                         sourceHeight: m?.pixelHeight ?? panel.height) {
            SenderLog.info("Capture stream recovery failed: \(error)")
            transport.stop("Capture stream recovery failed: \(error)")
        }
    }

    @MainActor
    private func startModeWatcher(id: CGDirectDisplayID, initialTarget: SavedDisplayMode, allowedPointSizes: [(Int, Int)]) {
        let settleUntil = ProcessInfo.processInfo.systemUptime + 2.0
        var lastSize = CGSize(width: initialTarget.pointsWide, height: initialTarget.pointsHigh)
        var lastPixels = CGSize(width: initialTarget.pixelsWide, height: initialTarget.pixelsHigh)
        var correctedDuringSettle = false
        var tried1xPanel = initialTarget.pointsWide == panel.width && initialTarget.pointsHigh == panel.height
        var rebuildFailures = 0
        var nextRebuildAt = 0.0
        modeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !self.stopped, !self.resetting,
                      var m = CGDisplayCopyDisplayMode(id) else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                if now < settleUntil {
                    if m.width != initialTarget.pointsWide || m.height != initialTarget.pointsHigh ||
                       (initialTarget.pointsWide != self.panel.width &&
                        (m.pixelWidth != initialTarget.pixelsWide || m.pixelHeight != initialTarget.pixelsHigh)) {
                        correctedDuringSettle = true
                        await DisplaySetupGate.shared.run {
                            guard !Task.isCancelled, !self.stopped, !self.resetting else { return }
                            self.selectNativeMode(id: id, pointsWide: initialTarget.pointsWide, pointsHigh: initialTarget.pointsHigh,
                                                  pixelsWide: initialTarget.pixelsWide, pixelsHigh: initialTarget.pixelsHigh)
                        }
                    }
                    continue
                }
                if correctedDuringSettle {
                    correctedDuringSettle = false
                    if m.width == initialTarget.pointsWide, m.height == initialTarget.pointsHigh,
                       (m.pixelWidth != Int(lastPixels.width) || m.pixelHeight != Int(lastPixels.height)) {
                        self.refreshDisplayState()
                        switch await self.rebuildStream(id: id, sourceWidth: m.pixelWidth, sourceHeight: m.pixelHeight) {
                        case .succeeded:
                            rebuildFailures = 0
                            nextRebuildAt = 0
                            lastSize = CGSize(width: m.width, height: m.height)
                            lastPixels = CGSize(width: m.pixelWidth, height: m.pixelHeight)
                        case .skipped:
                            continue
                        case .failed(let error):
                            rebuildFailures += 1
                            SenderLog.info("Capture stream rebuild failed (\(rebuildFailures)/5): \(error)")
                            if CaptureSession.isPermissionDenied(error) || rebuildFailures >= 5 {
                                self.transport.stop("Capture stream rebuild failed: \(error)")
                                return
                            }
                            let delay = min(15.0, Double(1 << min(rebuildFailures - 1, 4)))
                            nextRebuildAt = ProcessInfo.processInfo.systemUptime + delay
                            continue
                        }
                    }
                }
                if m.width == self.panel.width, m.height == self.panel.height, m.pixelWidth > self.panel.width {
                    if !tried1xPanel {
                        tried1xPanel = true
                        await DisplaySetupGate.shared.run {
                            guard !Task.isCancelled, !self.stopped, !self.resetting else { return }
                            self.selectNativeMode(id: id, pointsWide: self.panel.width, pointsHigh: self.panel.height,
                                                  pixelsWide: self.panel.width, pixelsHigh: self.panel.height)
                        }
                        if let updated = CGDisplayCopyDisplayMode(id) { m = updated }
                    }
                } else if m.width != self.panel.width || m.height != self.panel.height {
                    tried1xPanel = false
                }
                let size = CGSize(width: m.width, height: m.height)
                let pixels = CGSize(width: m.pixelWidth, height: m.pixelHeight)
                guard size.width > 0, size.height > 0, (size != lastSize || pixels != lastPixels) else {
                    rebuildFailures = 0
                    nextRebuildAt = 0
                    continue
                }
                guard ProcessInfo.processInfo.systemUptime >= nextRebuildAt else { continue }
                self.refreshDisplayState()
                switch await self.rebuildStream(id: id, sourceWidth: m.pixelWidth, sourceHeight: m.pixelHeight) {
                case .succeeded:
                    rebuildFailures = 0
                    nextRebuildAt = 0
                case .skipped:
                    continue
                case .failed(let error):
                    rebuildFailures += 1
                    SenderLog.info("Capture stream rebuild failed (\(rebuildFailures)/5): \(error)")
                    if CaptureSession.isPermissionDenied(error) || rebuildFailures >= 5 {
                        self.transport.stop("Capture stream rebuild failed: \(error)")
                        return
                    }
                    let delay = min(15.0, Double(1 << min(rebuildFailures - 1, 4)))
                    nextRebuildAt = ProcessInfo.processInfo.systemUptime + delay
                    continue
                }
                lastSize = size
                lastPixels = pixels
                let chosen = SavedDisplayMode(
                    pointsWide: m.width, pointsHigh: m.height,
                    pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight)
                DisplayModeDB.shared.save(for: self.panel, mode: chosen, allowedPointSizes: allowedPointSizes)
                SenderLog.info("Updated capture stream for scaled mode \(m.width)x\(m.height) (px=\(m.pixelWidth)x\(m.pixelHeight))")
            }
        }
    }

    @MainActor
    private func shareable(_ id: CGDirectDisplayID, checkCancellation: Bool = true) async throws -> SCDisplay {
        for _ in 0..<40 {
            if checkCancellation { try Task.checkCancellation() }
            let displays = try await SCShareableContent.current.displays
            if let match = displays.first(where: { $0.displayID == id && $0.width > 0 && $0.height > 0 }) {
                return match
            }
            if checkCancellation {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                try? await Task.sleep(for: .milliseconds(50))
            }
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

    private enum SubmitOutcome {
        case submitted
        case busy
        case paced(TimeInterval)
        case stopped
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
        switch submitFrame(image, pts: pts, forceAdmission: false, storeIfBusy: true) {
        case .submitted, .stopped:
            refineTimer?.cancel()
            refineTimer = nil
        case .paced(let delay):
            scheduleRefinement(after: delay)
        case .busy:
            scheduleRefinement(after: FramePacer.busyFallbackDelay)
        }
    }

    private func drainPendingFrame(forceAdmission: Bool) {
        lock.lock()
        guard !stopped, let image = pendingImage else {
            lock.unlock()
            return
        }
        let pts = pendingPts.isValid ? pendingPts : CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()
        switch submitFrame(image, pts: pts, forceAdmission: forceAdmission, storeIfBusy: false) {
        case .submitted, .stopped:
            refineTimer?.cancel()
            refineTimer = nil
        case .paced(let delay):
            scheduleRefinement(after: delay)
        case .busy:
            scheduleRefinement(after: FramePacer.busyFallbackDelay)
        }
    }

    private func scheduleRefinement(after delay: TimeInterval) {
        refineTimer?.cancel()
        let clampedDelay = max(FramePacer.minimumPacedDelay, delay)
        let delayUs = max(1_000, Int((clampedDelay * 1_000_000.0).rounded(.up)))
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + .microseconds(delayUs), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refineTimer?.cancel()
            self.refineTimer = nil
            self.drainPendingFrame(forceAdmission: true)
        }
        timer.resume()
        refineTimer = timer
    }

    private func resolveMetalScaler() -> MetalImageScaler? {
        if !metalScalerInitialized {
            metalScalerInitialized = true
            metalScaler = MetalImageScaler()
            if metalScaler == nil {
                SenderLog.info("MetalPerformanceShaders scaler unavailable; falling back to CoreImage")
            }
        }
        return metalScaler
    }

    private func scaledBuffer(_ image: CVImageBuffer) -> CVImageBuffer {
        let srcW = CVPixelBufferGetWidth(image), srcH = CVPixelBufferGetHeight(image)
        if srcW == panel.width && srcH == panel.height { return image }
        if scalePool == nil {
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ]
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: panel.width,
                kCVPixelBufferHeightKey: panel.height,
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &scalePool)
        }
        guard let pool = scalePool else { return image }
        var dstOpt: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOpt) == kCVReturnSuccess, let dst = dstOpt else { return image }
        let isBGRA = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA
        if isBGRA, let scaler = resolveMetalScaler(), scaler.scale(from: image, to: dst) {
            if let srgbSpace {
                CVBufferSetAttachment(dst, kCVImageBufferCGColorSpaceKey, srgbSpace, .shouldPropagate)
            }
            return dst
        }
        let input = (isBGRA
            ? CIImage(cvPixelBuffer: image, options: [.colorSpace: NSNull()])
            : CIImage(cvPixelBuffer: image)
        ).clampedToExtent()
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        let scaleY = Double(panel.height) / Double(max(1, srcH))
        let scaleX = Double(panel.width) / Double(max(1, srcW))
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(scaleX / max(1e-6, scaleY), forKey: kCIInputAspectRatioKey)
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

    private func submitFrame(_ image: CVImageBuffer, pts: CMTime, forceAdmission: Bool, storeIfBusy: Bool) -> SubmitOutcome {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped, let encoder else { lock.unlock(); return .stopped }
        switch pacer.tryAdmit(now: now, transportCanAccept: transport.canAcceptVideo, forceAdmission: forceAdmission) {
        case .busy:
            if storeIfBusy {
                if pendingImage != nil {
                    framesDropped += 1
                }
                pendingImage = image
                pendingPts = pts
            }
            lock.unlock()
            return .busy
        case .paced(let delay):
            if storeIfBusy {
                if pendingImage != nil {
                    framesDropped += 1
                }
                pendingImage = image
                pendingPts = pts
            }
            lock.unlock()
            return .paced(delay)
        case .admit:
            break
        }
        if storeIfBusy && pendingImage != nil {
            framesDropped += 1
        }
        pendingImage = nil
        pendingPts = .invalid
        let properties = needsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        needsKeyframe = false
        lock.unlock()

        let frameStart = now
        let encodeImage = scaledBuffer(image)
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: encodeImage, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, output in
            self?.encoded(status: status, sample: output, frameStart: frameStart)
        }
        if status != noErr {
            SenderLog.info("Video encode submit failed: status=\(status)")
            finishEncodeFailure(fatal: true)
        }
        return .submitted
    }

    // A bad frame is skipped and the next frame is forced to a keyframe. Only a
    // run of consecutive failures ends the session, so a single oversized or
    // dropped frame never tears down the stream, and a persistent fault never
    // freezes the picture silently.
    private func handleEncodeError(_ detail: String) {
        lock.lock()
        consecutiveEncodeErrors += 1
        let count = consecutiveEncodeErrors
        lock.unlock()
        SenderLog.info("Video encode/frame error: \(detail) consecutive=\(count)")
        if count >= 3 {
            finishEncodeFailure(fatal: true)
        } else {
            requestKeyframe()
            finishEncodeFailure(fatal: false)
        }
    }

    private func finishEncodeFailure(fatal: Bool) {
        var hasPending = false
        var ended = false
        lock.lock()
        pacer.finishEncode(handoffToSend: false)
        ended = stopped
        if !fatal {
            framesDropped += 1
        }
        hasPending = !ended && !fatal && pendingImage != nil
        lock.unlock()
        if fatal && !ended {
            transport.stop("Video encoder failed")
        } else if hasPending {
            sampleQueue.async { [weak self] in
                self?.drainPendingFrame(forceAdmission: false)
            }
        }
    }

    private func encoded(status: OSStatus, sample: CMSampleBuffer?, frameStart: TimeInterval) {
        let encodeDone = ProcessInfo.processInfo.systemUptime
        guard status == noErr, let sample else {
            handleEncodeError("status=\(status) sample=\(sample == nil ? "nil" : "present")")
            return
        }
        let encodeMs = max(0.0, (encodeDone - frameStart) * 1000.0)
        var shouldSend = false
        var hasPending = false
        lock.lock()
        if stopped {
            pacer.finishEncode(handoffToSend: false)
        } else {
            pacer.finishEncode(handoffToSend: true)
            shouldSend = true
            hasPending = pendingImage != nil
        }
        lock.unlock()
        if hasPending {
            sampleQueue.async { [weak self] in
                self?.drainPendingFrame(forceAdmission: false)
            }
        }
        guard shouldSend else { return }
        // VideoToolbox invokes output callbacks serially in submission order
        // when AllowFrameReordering is false; sendQueue preserves that exact
        // order while freeing the encoder slot immediately for the next frame.
        sendQueue.async { [weak self] in
            self?.deliverEncodedSample(sample, encodeMs: encodeMs)
        }
    }

    private func deliverEncodedSample(_ sample: CMSampleBuffer, encodeMs: Double) {
        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        if alreadyStopped {
            finishSend(failed: false, skipped: false, encodeMs: nil)
            return
        }
        guard let data = annexB(sample) else {
            let blockLen = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? -1
            handleSendError("annexB returned nil (blockBytes=\(blockLen), keyframe=\(isKeyframe(sample)))")
            return
        }
        do {
            if !(try transport.sendVideo(data)) {
                requestKeyframe()
                finishSend(failed: false, skipped: true, encodeMs: nil)
                return
            }
        } catch {
            handleSendError("sendVideo threw (\(error), bytes=\(data.count))")
            return
        }
        finishSend(failed: false, skipped: false, encodeMs: encodeMs)
    }

    private func handleSendError(_ detail: String) {
        lock.lock()
        consecutiveEncodeErrors += 1
        let count = consecutiveEncodeErrors
        lock.unlock()
        SenderLog.info("Video encode/frame error: \(detail) consecutive=\(count)")
        if count >= 3 {
            finishSend(failed: true, skipped: false, encodeMs: nil)
        } else {
            requestKeyframe()
            finishSend(failed: false, skipped: true, encodeMs: nil)
        }
    }

    private func finishSend(failed: Bool, skipped: Bool, encodeMs: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        var hasPending = false
        var ended = false
        var statsLine: String?
        lock.lock()
        pacer.finishSend()
        ended = stopped
        if skipped {
            framesDropped += 1
        } else if !failed, let encodeMs {
            consecutiveEncodeErrors = 0
            framesEncoded += 1
            totalEncodeMs += encodeMs
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
                self?.drainPendingFrame(forceAdmission: false)
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
            guard let self, !self.stopped, !self.resetting, stream === self.stream else { return }
            SenderLog.info("Capture stream interrupted (\(error.localizedDescription)); recovering in place")
            await self.recoverStream()
        }
    }

    @MainActor
    func stopAsync(_ reason: String) async {
        let stats: (UInt64, UInt64, Double)? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            pendingImage = nil
            pendingPts = .invalid
            return (framesEncoded, framesDropped, totalEncodeMs)
        }
        guard let (encodedCount, droppedCount, totalMs) = stats else { return }
        transport.onVideoDrained = nil
        modeTask?.cancel(); modeTask = nil
        if reconfigRegistered, let ctx = reconfigContext {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, ctx)
            reconfigRegistered = false
            reconfigContext = nil
        }
        inputQueue.sync {
            self.input?.cancel()
            self.input?.detach()
            self.input = nil
        }
        if let activeStream = stream {
            stream = nil
            try? activeStream.removeStreamOutput(self, type: .screen)
            try? await activeStream.stopCapture()
        }
        sampleQueue.sync {
            self.refineTimer?.cancel()
            self.refineTimer = nil
        }
        finishTeardown(reason: reason, encodedCount: encodedCount, droppedCount: droppedCount, totalMs: totalMs)
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
            self.input?.detach()
            self.input = nil
        }
        if let activeStream = stream {
            stream = nil
            try? activeStream.removeStreamOutput(self, type: .screen)
            activeStream.stopCapture { _ in }
        }
        finishTeardown(reason: reason, encodedCount: encodedCount, droppedCount: droppedCount, totalMs: totalMs)
    }

    @MainActor
    private func finishTeardown(reason: String, encodedCount: UInt64, droppedCount: UInt64, totalMs: Double) {
        if let encoder = encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        metalScaler?.flush()
        metalScaler = nil
        metalScalerInitialized = false
        if let scalePool { CVPixelBufferPoolFlush(scalePool, .excessBuffers) }
        scalePool = nil
        display = nil
        if let serial = claimedSerialNum {
            ActiveDisplayRegistry.shared.release(serialNum: serial)
            claimedSerialNum = nil
        }
        VirtualDisplayCoordinator.shared.unregister(self)
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
