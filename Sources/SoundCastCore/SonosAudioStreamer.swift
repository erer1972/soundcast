import Foundation

/// One Sonos S1 session backed by an HTTP WAV stream from a dedicated ring.
/// Construction is inert; playback starts only when `start()` is called.
public final class SonosAudioStreamer: @unchecked Sendable {
    public enum StreamerError: Error, CustomStringConvertible {
        case alreadyStarted
        case invalidDescriptionAddress
        case stopped

        public var description: String {
            switch self {
            case .alreadyStarted: return "Sonos audio streamer is already started"
            case .invalidDescriptionAddress: return "Sonos description URL has no IPv4 host"
            case .stopped: return "Sonos startup was stopped"
            }
        }
    }

    private let receiver: SonosReceiver
    private let source: RingBuffer
    private let sampleRate: Double
    private let delaySeconds: Double
    private let lock = NSLock()
    private var mirror: RingBuffer?
    private var audioServer: SonosHTTPAudioServer?
    private var streamURI: URL?
    private var starting = false
    private var running = false
    private var stopping = false
    private var sessionID: UUID?
    private var startupID: UUID?
    private var stopID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    private enum StopAction {
        case startup(UUID)
        case waiting(UUID)
        case cleanup(SonosHTTPAudioServer, RingBuffer, URL, Task<Void, Never>?, UUID)
        case none
    }

    public init(receiver: SonosReceiver, source: RingBuffer, sampleRate: Double, delaySeconds: Double = 0) {
        self.receiver = receiver
        self.source = source
        self.sampleRate = sampleRate
        self.delaySeconds = delaySeconds.isFinite ? max(0, min(10, delaySeconds)) : 0
    }

    /// Starts a per-receiver WAV feed and asks the Sonos to play its URI.
    public func start() async throws {
        try SonosHTTPAudioServer.validateSampleRate(sampleRate)
        guard let session = beginStart() else { throw StreamerError.alreadyStarted }

        let mirror = RingBuffer(capacitySamples: Int(sampleRate.rounded() * (delaySeconds + 2)) * 2)
        let audioServer = SonosHTTPAudioServer(source: mirror, sampleRate: sampleRate, delaySeconds: delaySeconds) { [weak self] in
            self?.beginRecovery(for: session)
        }
        source.addMirror(mirror)

        var uri: URL?
        do {
            guard let peerIPv4 = receiver.descriptionURL.host else {
                throw StreamerError.invalidDescriptionAddress
            }
            let streamURL = try await audioServer.start(peerIPv4: peerIPv4)
            uri = streamURL
            try checkStarting(session)
            let metadata = SonosUPnPClient.liveWAVMetadata(
                uri: streamURL, sampleRate: UInt32(sampleRate.rounded()), channels: 2, bitsPerSample: 16
            )
            NSLog("[SoundCast][SonosAudioStreamer] setting transport URI")
            try await SonosUPnPClient.setAVTransportURI(for: receiver, uri: streamURL, metadata: metadata)
            try checkStarting(session)
            NSLog("[SoundCast][SonosAudioStreamer] transport URI set; requesting playback")
            try await SonosUPnPClient.play(receiver)
            NSLog("[SoundCast][SonosAudioStreamer] playback request completed")
            guard finishStart(mirror: mirror, audioServer: audioServer, uri: streamURL, session: session) else {
                throw StreamerError.stopped
            }
        } catch {
            if startupWasStopped(), let uri,
               let currentURI = try? await SonosUPnPClient.getCurrentURI(for: receiver), currentURI == uri.absoluteString {
                try? await SonosUPnPClient.stop(receiver)
            }
            audioServer.stop()
            source.removeMirror(mirror)
            finishFailedStart()
            throw error
        }
    }

    /// Stops Sonos playback, closes its stream server, and removes the mirror.
    public func stop() async {
        switch beginStop() {
        case .startup(let startup):
            await waitForStartup(startup)
        case .waiting(let stop):
            await waitForStop(stop)
        case .cleanup(let audioServer, let mirror, let uri, let recoveryTask, let stop):
            recoveryTask?.cancel()
            await recoveryTask?.value
            if let currentURI = try? await SonosUPnPClient.getCurrentURI(for: receiver), currentURI == uri.absoluteString {
                try? await SonosUPnPClient.stop(receiver)
            }
            audioServer.stop()
            source.removeMirror(mirror)
            finishStop(stop)
        case .none:
            return
        }
    }

    public func disconnectClientsForTesting(unavailableSeconds: TimeInterval = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return audioServer?.disconnectClientsForTesting(unavailableSeconds: unavailableSeconds) ?? 0
    }

    private func beginStart() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !starting, !running, !stopping else { return nil }
        let session = UUID()
        sessionID = session
        startupID = session
        starting = true
        return session
    }

    private func finishStart(mirror: RingBuffer, audioServer: SonosHTTPAudioServer, uri: URL, session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard starting, !stopping, sessionID == session else { return false }
        self.mirror = mirror
        self.audioServer = audioServer
        streamURI = uri
        starting = false
        startupID = nil
        running = true
        return true
    }

    private func finishFailedStart() {
        lock.lock()
        starting = false
        stopping = false
        sessionID = nil
        startupID = nil
        let waiters = startWaiters
        startWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func checkStarting(_ session: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard starting, !stopping, sessionID == session else { throw StreamerError.stopped }
    }

    private func startupWasStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return starting && stopping
    }

    private func waitForStartup(_ startup: UUID) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if starting && startupID == startup {
                startWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func beginStop() -> StopAction {
        lock.lock()
        defer { lock.unlock() }
        if starting, let startupID {
            stopping = true
            sessionID = nil
            return .startup(startupID)
        }
        if stopping, let stopID { return .waiting(stopID) }
        guard running, let audioServer, let mirror, let streamURI, let sessionID else { return .none }
        running = false
        stopping = true
        stopID = sessionID
        self.sessionID = nil
        self.audioServer = nil
        self.mirror = nil
        self.streamURI = nil
        let task = recoveryTask
        recoveryTask = nil
        return .cleanup(audioServer, mirror, streamURI, task, sessionID)
    }

    private func waitForStop(_ stop: UUID) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopping && stopID == stop {
                stopWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func finishStop(_ stop: UUID) {
        lock.lock()
        guard stopID == stop else { lock.unlock(); return }
        stopping = false
        stopID = nil
        let waiters = stopWaiters
        stopWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    private func beginRecovery(for session: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard running, sessionID == session, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            await self?.recover(for: session)
        }
    }

    private func recover(for session: UUID) async {
        defer { finishRecovery(for: session) }
        for delay: UInt64 in [2, 3, 5, 8, 13] {
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard isRunning(session), !Task.isCancelled else { return }
                let info = try await SonosUPnPClient.getTransportInfo(for: receiver)
                guard isRunning(session), !Task.isCancelled else { return }
                if info.currentTransportState == "PLAYING" { return }
                if info.currentTransportState == "STOPPED" {
                    guard let expectedURI = currentURI(for: session),
                          try await SonosUPnPClient.getCurrentURI(for: receiver) == expectedURI.absoluteString,
                          isRunning(session), !Task.isCancelled else { return }
                    NSLog("[SoundCast][SonosAudioStreamer] retrying playback after media disconnect")
                    try await SonosUPnPClient.play(receiver)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard isRunning(session), !Task.isCancelled else { return }
                    let result = try await SonosUPnPClient.getTransportInfo(for: receiver)
                    guard isRunning(session), !Task.isCancelled else { return }
                    if result.currentTransportState == "PLAYING" { return }
                    if result.currentTransportState != "STOPPED" && result.currentTransportState != "TRANSITIONING" { return }
                    continue
                }
                if info.currentTransportState != "TRANSITIONING" { return }
            } catch {
                if Task.isCancelled { return }
                NSLog("[SoundCast][SonosAudioStreamer] recovery attempt failed: \(error)")
            }
        }
    }

    private func isRunning(_ session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && sessionID == session
    }

    private func currentURI(for session: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return running && sessionID == session ? streamURI : nil
    }

    private func finishRecovery(for session: UUID) {
        lock.lock()
        if sessionID == session { recoveryTask = nil }
        lock.unlock()
    }
}