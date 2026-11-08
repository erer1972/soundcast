import Foundation
import Network

/// Streams live captured audio to one AirPlay 2 receiver over the
/// realtime (`type=96`) path verified audible on a real Apple TV
/// (design doc §12.5). Owns the RTSP session, the RTP data/control
/// sockets, and a streaming thread that reads from `source`.
///
/// Pacing is by wall clock, not by the capture callback: every tick the
/// thread sends as much audio as wall time says is due, zero-filling if
/// capture has nothing (so the receiver's timeline never stalls), and
/// nudges by single frames when the capture clock drifts against the
/// wall clock (keeps a small cushion in `source` between `lowWater` and
/// `highWater`). RTP time is anchored once: `startTimestamp` plays
/// exactly `latencyFrames` after `anchorTime`, and every sync packet
/// restates that same mapping.
public final class AirPlayRealtimeSender: @unchecked Sendable {
    public enum SenderError: Error, CustomStringConvertible {
        case notPaired
        case stopped
        case sessionLost(String)

        public var description: String {
            switch self {
            case .notPaired: return "this receiver isn't paired with SoundCast yet"
            case .sessionLost(let reason): return "session lost (\(reason))"
            case .stopped: return "stopped"
            }
        }
    }

    public let receiver: AirPlayResolvedReceiver
    /// Called (on an arbitrary thread) if the session dies after start.
    public var onFailure: (@Sendable (Error) -> Void)?

    private let identity: AirPlayIdentity
    private let ptpClock: AirPlayPTPClock
    private let source: RingBuffer
    private let inputSampleRate: Double

    private static let outputSampleRate = 44_100.0
    private static let framesPerPacket = 352
    /// 2 s, matching `latencyMax` and the `0xD7` anchor lead.
    private static let latencyFrames: UInt32 = 88_200

    private var connection: AirPlayRTSPConnection?
    private var eventConnection: AirPlayRTSPConnection?
    private var requestTarget = ""
    private var dataSocket: AirPlayUDPPort?
    private var controlSocket: AirPlayUDPPort?
    private var remoteDataPort: UInt16 = 0
    private var remoteControlPort: UInt16 = 0
    private var audioKey: [UInt8] = []

    private let rtsp = SerialAsyncQueue()
    private let stateLock = NSLock()
    private var running = false
    private var streamThread: Thread?
    private var keepAliveTask: Task<Void, Never>?
    private var pendingVolume: Float = 1.0
    private var audioStream: AirPlayRealtimeAudioStream?

    /// Packets resent on the receiver's request / requests we couldn't
    /// serve because the packet had already left the history.
    public var resendStats: (resent: Int, unavailable: Int) {
        stateLock.withLock { audioStream }?.resendStats ?? (0, 0)
    }

    public init(
        receiver: AirPlayResolvedReceiver,
        identity: AirPlayIdentity,
        ptpClock: AirPlayPTPClock,
        source: RingBuffer,
        inputSampleRate: Double
    ) {
        self.receiver = receiver
        self.identity = identity
        self.ptpClock = ptpClock
        self.source = source
        self.inputSampleRate = inputSampleRate
    }

    // MARK: - Lifecycle

    /// Pairs, negotiates the realtime stream, and starts streaming.
    public func start() async throws {
        try ptpClock.addPeer(ipv4: receiver.ipv4)
        do {
            try await establishSession()
        } catch {
            await tearDownSession(sendTeardown: false)
            throw error
        }
        stateLock.withLock { running = true }
        // Session-loss detection: the RTSP connection failing or being
        // closed, or the receiver closing the event connection (expected
        // when it ends the session itself, e.g. from its remote). PTP
        // Delay_Req can't be used: kaan only sends them during setup.
        connection?.onTermination { [weak self] reason in
            self?.fail(SenderError.sessionLost(reason))
        }
        eventConnection?.onTermination { [weak self] reason in
            self?.fail(SenderError.sessionLost(reason))
        }
        eventConnection?.watchForPeerClose()
        if let raw = ProcessInfo.processInfo.environment["SOUNDCAST_DEBUG_DROP_SESSION_AFTER"],
           let seconds = Double(raw), seconds > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                self?.fail(SenderError.sessionLost("debug: simulated drop after \(raw) s"))
            }
        }
        let thread = Thread { [weak self] in self?.streamLoop() }
        thread.name = "SoundCast.AirPlay.\(receiver.serviceName)"
        thread.qualityOfService = .userInteractive
        streamThread = thread
        thread.start()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                // 5 s (OwnTones uses 25 s) so a receiver that vanished
                // without closing anything is noticed quickly.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.rtsp.run { try await self.sendFeedback() }
                } catch {
                    self.fail(error)
                    return
                }
            }
        }
    }

    /// Stops streaming and tears down the session (best effort).
    public func stop() async {
        stateLock.withLock { running = false }
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await tearDownSession(sendTeardown: true)
    }

    /// Receiver volume, 0...1 (0 mutes). Mapped like OwnTones: -30...0 dB.
    public func setVolume(_ gain: Float) {
        pendingVolume = max(0, min(1, gain))
        let gain = pendingVolume
        Task { [weak self] in
            guard let self else { return }
            try? await self.rtsp.run { try await self.sendVolume(gain) }
        }
    }

    // MARK: - Session setup / teardown

    private func establishSession() async throws {
        let host = NWEndpoint.Host(receiver.scopedIPv6)
        let connection = AirPlayRTSPConnection(host: host, port: NWEndpoint.Port(rawValue: receiver.port)!)
        self.connection = connection
        try await connection.connect()

        let keys: AirPlayPairVerify.SessionKeys
        do {
            keys = try await AirPlayPairVerify.run(connection: connection, identity: identity)
        } catch AirPlayPairVerify.PairVerifyError.rejected {
            throw SenderError.notPaired
        }
        connection.enableEncryption(readKey: keys.readKey, writeKey: keys.writeKey)
        audioKey = keys.audioKey.withUnsafeBytes { Array($0) }

        let info = try await connection.send(method: "GET", path: "/info", extraHeaders: ["X-Apple-ProtocolVersion": "1"])
        guard info.statusCode == 200 else {
            throw AirPlayStreamSetup.StreamError.unexpectedStatus(info.statusCode, info.body)
        }

        let dataSocket = try AirPlayUDPPort(localAddress: ptpClock.localAddress)
        let controlSocket = try AirPlayUDPPort(localAddress: ptpClock.localAddress)
        self.dataSocket = dataSocket
        self.controlSocket = controlSocket

        let streamConnectionID = Int.random(in: 1...Int(UInt32.max))
        requestTarget = "rtsp://[\(receiver.ipv6LinkLocal)]/\(streamConnectionID)"
        let setup = try await AirPlayStreamSetup.run(
            connection: connection,
            host: host,
            requestTarget: requestTarget,
            sessionUUID: UUID().uuidString,
            sharedKey: audioKey,
            samplesPerFrame: Self.framesPerPacket,
            timingProtocol: "PTP",
            ptpClock: ptpClock,
            streamType: 96,
            localControlPort: controlSocket.port,
            localDataPort: dataSocket.port,
            streamConnectionID: streamConnectionID,
            recordBeforeStream: true,
            timingPeers: [receiver.ipv4, ptpClock.localAddress]
        )
        eventConnection = setup.eventConnection
        remoteDataPort = UInt16(setup.dataPort)
        remoteControlPort = UInt16(setup.controlPort)
        try await sendVolume(pendingVolume)
    }

    private func tearDownSession(sendTeardown: Bool) async {
        if let thread = streamThread {
            while !thread.isFinished { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        streamThread = nil
        if sendTeardown, let connection, !requestTarget.isEmpty {
            let target = requestTarget
            let rtsp = self.rtsp
            try? await withTimeout(seconds: 2) {
                _ = try await rtsp.run {
                    let body = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
                    return try await connection.send(
                        method: "TEARDOWN", path: target,
                        extraHeaders: AirPlayStreamSetup.streamHeaders.merging(
                            ["Content-Type": "application/x-apple-binary-plist"]) { _, new in new },
                        body: Array(body)
                    ).statusCode
                }
            }
        }
        eventConnection?.close()
        connection?.close()
        eventConnection = nil
        connection = nil
        dataSocket = nil
        controlSocket = nil
        ptpClock.removePeer(ipv4: receiver.ipv4)
    }

    private func sendVolume(_ gain: Float) async throws {
        guard let connection, !requestTarget.isEmpty else { return }
        let decibels = gain <= 0 ? -144.0 : -30.0 + 30.0 * Double(gain)
        let response = try await connection.send(
            method: "SET_PARAMETER", path: requestTarget,
            extraHeaders: AirPlayStreamSetup.streamHeaders.merging(["Content-Type": "text/parameters"]) { _, new in new },
            body: Array(String(format: "volume: %.6f\r\n", decibels).utf8)
        )
        guard response.statusCode == 200 else {
            throw AirPlayStreamSetup.StreamError.unexpectedStatus(response.statusCode, response.body)
        }
    }

    private func sendFeedback() async throws {
        guard let connection else { throw SenderError.stopped }
        let response = try await connection.send(method: "POST", path: "/feedback", extraHeaders: AirPlayStreamSetup.streamHeaders)
        guard response.statusCode == 200 else {
            throw AirPlayStreamSetup.StreamError.unexpectedStatus(response.statusCode, response.body)
        }
    }

    private func fail(_ error: Error) {
        let wasRunning = stateLock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        guard wasRunning else { return }
        NSLog("[SoundCast][AirPlay] \(receiver.serviceName) failed: \(error)")
        onFailure?(error)
    }

    private var isRunning: Bool { stateLock.withLock { running } }

    // MARK: - Streaming thread

    private func streamLoop() {
        guard let dataSocket, let controlSocket else { return }
        let encoder: ALACEncoder
        do {
            encoder = try ALACEncoder(
                inputSampleRate: inputSampleRate,
                outputSampleRate: Self.outputSampleRate,
                framesPerPacket: Self.framesPerPacket
            )
        } catch {
            fail(error)
            return
        }
        let stream = AirPlayRealtimeAudioStream(
            udpPort: dataSocket,
            receiverIPv4: receiver.scopedIPv6,
            receiverPort: remoteDataPort,
            audioKey: audioKey,
            initialSequence: UInt16.random(in: 0...UInt16.max)
        )

        stateLock.withLock { audioStream = stream }
        // Retransmit requests arrive on our control port: 8 bytes,
        // `80 D5 <2 bytes> <first seq BE16> <count BE16>` (OwnTones'
        // control_svc_cb). Answered off the streaming thread.
        controlSocket.startReceiving(queue: DispatchQueue(label: "SoundCast.AirPlay.control")) { packet in
            guard packet.count >= 8, packet[0] == 0x80, packet[1] == 0xD5 else { return }
            let first = UInt16(packet[4]) << 8 | UInt16(packet[5])
            let count = UInt16(packet[6]) << 8 | UInt16(packet[7])
            stream.resend(first: first, count: count)
        }

        let chunkFrames = max(1, Int(inputSampleRate / 100)) // 10 ms
        let cushionFrames = Int(inputSampleRate * 0.06)
        let lowWater = Int(inputSampleRate * 0.02)
        let highWater = Int(inputSampleRate * 0.12)

        // Let capture build the cushion first (up to 1 s), and drop any
        // stale backlog beyond it.
        let primeDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while isRunning, source.framesAvailable / 2 < cushionFrames,
              DispatchTime.now().uptimeNanoseconds < primeDeadline {
            usleep(2_000)
        }
        let excess = source.framesAvailable / 2 - cushionFrames
        if excess > 0 {
            var scratch = [Float](repeating: 0, count: excess * 2)
            scratch.withUnsafeMutableBufferPointer { source.read(into: $0.baseAddress!, count: excess * 2) }
        }

        let startTimestamp = UInt32.random(in: 0...UInt32.max)
        var nextTimestamp = startTimestamp
        let anchorUptime = DispatchTime.now().uptimeNanoseconds
        let anchorClock = AirPlayPTPClock.now()
        func syncPacket(first: Bool) -> [UInt8] {
            // RTP frame that should be audible `latencyFrames` from now.
            let elapsed = Double(AirPlayPTPClock.now() &- anchorClock) / 1e9
            let due = startTimestamp &+ UInt32(truncatingIfNeeded: Int64(elapsed * Self.outputSampleRate))
            return ptpClock.realtimeSyncPacket(rtpTimestamp: due, first: first)
        }
        do {
            try controlSocket.send(syncPacket(first: true), to: receiver.scopedIPv6, port: remoteControlPort)
        } catch {
            fail(error)
            return
        }

        var inputFed = 0
        var lastSyncUptime = anchorUptime
        var lastCorrectionUptime = anchorUptime
        var buffer = [Float](repeating: 0, count: (chunkFrames + 1) * 2)
        var sendErrors = 0
        // Health counters, logged every 30 s: frames dropped/duplicated by
        // drift correction, reads that came up short (audible gaps), and
        // the cushion's range over the window.
        var droppedFrames = 0, duplicatedFrames = 0, underruns = 0
        var minFill = Int.max, maxFill = 0
        var lastStatsUptime = anchorUptime

        while isRunning {
            let now = DispatchTime.now().uptimeNanoseconds
            let inputDue = Int(Double(now - anchorUptime) / 1e9 * inputSampleRate)
            while inputFed + chunkFrames <= inputDue {
                // Single-frame drift correction, at most every 50 ms.
                let fill = source.framesAvailable / 2
                minFill = min(minFill, fill)
                maxFill = max(maxFill, fill)
                var readFrames = chunkFrames
                if now - lastCorrectionUptime > 50_000_000 {
                    if fill > highWater {
                        readFrames = chunkFrames + 1
                        lastCorrectionUptime = now
                        droppedFrames += 1
                    } else if fill > 0 && fill < lowWater {
                        readFrames = chunkFrames - 1
                        lastCorrectionUptime = now
                        duplicatedFrames += 1
                    }
                }
                if fill > 0 && fill < readFrames { underruns += 1 }
                buffer.withUnsafeMutableBufferPointer {
                    source.read(into: $0.baseAddress!, count: readFrames * 2)
                }
                if readFrames < chunkFrames { // duplicate the last frame
                    buffer[(chunkFrames - 1) * 2] = buffer[(readFrames - 1) * 2]
                    buffer[(chunkFrames - 1) * 2 + 1] = buffer[(readFrames - 1) * 2 + 1]
                }
                // readFrames > chunkFrames: the extra frame is dropped.
                inputFed += chunkFrames
                do {
                    for packet in try encoder.encode(interleavedSamples: Array(buffer[0..<(chunkFrames * 2)])) {
                        try stream.sendFrame(packet, timestamp: nextTimestamp, isFirst: false)
                        nextTimestamp &+= UInt32(Self.framesPerPacket)
                    }
                    sendErrors = 0
                } catch {
                    sendErrors += 1
                    if sendErrors > 200 { // ~2 s of consecutive failures
                        fail(error)
                        return
                    }
                }
            }
            if now - lastSyncUptime >= 1_000_000_000 {
                try? controlSocket.send(syncPacket(first: false), to: receiver.scopedIPv6, port: remoteControlPort)
                lastSyncUptime = now
            }
            if now - lastStatsUptime >= 30_000_000_000 {
                let resends = stream.resendStats
                NSLog("[SoundCast][AirPlay] \(receiver.serviceName): %.0f s, cushion %d–%d frames, drift-corrected −%d/+%d frames, short reads %d, resent %d (%d unavailable)",
                      Double(now - anchorUptime) / 1e9, minFill == Int.max ? 0 : minFill, maxFill,
                      droppedFrames, duplicatedFrames, underruns, resends.resent, resends.unavailable)
                droppedFrames = 0; duplicatedFrames = 0; underruns = 0
                minFill = Int.max; maxFill = 0
                lastStatsUptime = now
            }
            usleep(4_000)
        }
    }
}

/// Runs async operations one at a time, in submission order — RTSP is a
/// strict request/response protocol on one connection, so volume changes,
/// keepalives, and teardown must not interleave.
final class SerialAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            let previous = tail
            let task = Task<T, Error> {
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}

/// Returns when `operation` finishes or `seconds` pass, whichever is
/// first. Unlike a task group this doesn't wait for a non-cancellable
/// operation (an RTSP send) to finish; the caller closes the connection
/// afterwards, which makes a hung send fail on its own.
private func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
    let once = Once()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        Task {
            do {
                try await operation()
                once.run { continuation.resume() }
            } catch {
                once.run { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            once.run { continuation.resume(throwing: CancellationError()) }
        }
    }
}
