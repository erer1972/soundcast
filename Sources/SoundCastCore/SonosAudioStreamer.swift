import Foundation

/// One Sonos S1 session backed by an HTTP WAV stream from a dedicated ring.
/// Construction is inert; playback starts only when `start()` is called.
public final class SonosAudioStreamer: @unchecked Sendable {
    public enum StreamerError: Error, CustomStringConvertible {
        case alreadyStarted
        case invalidDescriptionAddress

        public var description: String {
            switch self {
            case .alreadyStarted: return "Sonos audio streamer is already started"
            case .invalidDescriptionAddress: return "Sonos description URL has no IPv4 host"
            }
        }
    }

    private let receiver: SonosReceiver
    private let source: RingBuffer
    private let sampleRate: Double
    private let lock = NSLock()
    private var mirror: RingBuffer?
    private var audioServer: SonosHTTPAudioServer?
    private var starting = false
    private var running = false

    public init(receiver: SonosReceiver, source: RingBuffer, sampleRate: Double) {
        self.receiver = receiver
        self.source = source
        self.sampleRate = sampleRate
    }

    /// Starts a per-receiver WAV feed and asks the Sonos to play its URI.
    public func start() async throws {
        guard beginStart() else { throw StreamerError.alreadyStarted }

        let mirror = RingBuffer(capacitySamples: Int(sampleRate.rounded()) * 2 * 2)
        let audioServer = SonosHTTPAudioServer(source: mirror, sampleRate: sampleRate)
        source.addMirror(mirror)

        do {
            guard let peerIPv4 = receiver.descriptionURL.host else {
                throw StreamerError.invalidDescriptionAddress
            }
            let uri = try await audioServer.start(peerIPv4: peerIPv4)
            let metadata = SonosUPnPClient.liveWAVMetadata(
                uri: uri, sampleRate: UInt32(sampleRate.rounded()), channels: 2, bitsPerSample: 16
            )
            NSLog("[SoundCast][SonosAudioStreamer] setting transport URI")
            try await SonosUPnPClient.setAVTransportURI(for: receiver, uri: uri, metadata: metadata)
            NSLog("[SoundCast][SonosAudioStreamer] transport URI set; requesting playback")
            try await SonosUPnPClient.play(receiver)
            NSLog("[SoundCast][SonosAudioStreamer] playback request completed")
            finishStart(mirror: mirror, audioServer: audioServer)
        } catch {
            audioServer.stop()
            source.removeMirror(mirror)
            finishFailedStart()
            throw error
        }
    }

    /// Stops Sonos playback, closes its stream server, and removes the mirror.
    public func stop() async {
        guard let (audioServer, mirror) = takeRunningResources() else { return }
        try? await SonosUPnPClient.stop(receiver)
        audioServer.stop()
        source.removeMirror(mirror)
    }

    private func beginStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !starting, !running else { return false }
        starting = true
        return true
    }

    private func finishStart(mirror: RingBuffer, audioServer: SonosHTTPAudioServer) {
        lock.lock()
        self.mirror = mirror
        self.audioServer = audioServer
        starting = false
        running = true
        lock.unlock()
    }

    private func finishFailedStart() {
        lock.lock()
        starting = false
        lock.unlock()
    }

    private func takeRunningResources() -> (SonosHTTPAudioServer, RingBuffer)? {
        lock.lock()
        defer { lock.unlock() }
        guard running, let audioServer, let mirror else { return nil }
        running = false
        self.audioServer = nil
        self.mirror = nil
        return (audioServer, mirror)
    }
}