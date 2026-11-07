import Foundation
import Network

/// AirPlay RTSP SETUP (two phases) and RECORD — establishes the audio
/// stream after pair-verify's encrypted channel is up.
///
/// **Control setup verified end-to-end against a real Apple TV** (design
/// doc §12.5): both SETUP phases and RECORD succeeded. This does not
/// validate the audio data path. The current `type=103` buffered stream
/// uses TCP; Shairport Sync's receiver waits for valid PTP timing before
/// processing it, so this mode cannot be assumed to avoid PTP.
/// Reverse-engineered live, by reading each rejection and trying the
/// next concrete fix rather than guessing blindly — each one was a
/// real, confirmed requirement:
/// - `timingProtocol` in the phase-1 plist must be `"PTP"` — `"NTP"` got
///   a bare `400` with no body, before the server even inspected
///   anything else.
/// - RECORD's `500` (not `400` — the server accepted the request, then
///   failed) went away once a real TCP connection to the `eventPort`
///   phase 1 returned was open *before* sending RECORD. The server
///   seemingly expects that connection to exist, not any particular
///   bytes sent over it (none have been sent so far).
/// - `DACP-ID`/`Active-Remote` headers and `OPTIONS` before `SETUP`
///   turned out not to matter for this device — kept anyway since
///   they're cheap and commonly documented as required elsewhere.
///
/// Still unresolved: what the event connection is for, whether the
/// buffered path works with the Apple TV's timing requirements, and
/// which part of the current data frames makes the receiver reset the
/// connection.
public enum AirPlayStreamSetup {
    public enum StreamError: Error {
        case malformedResponse
        case unexpectedStatus(Int, [UInt8])
    }

    /// Headers real AirPlay senders include on every RTSP request past
    /// pairing (SETUP, RECORD, SET_PARAMETER, ...), used for remote-
    /// control device matching — commonly documented as required by
    /// receivers even when remote control itself isn't used.
    public static let streamHeaders: [String: String] = [
        "DACP-ID": "1A2B3C4D5E6F7788",
        "Active-Remote": "1986535575",
    ]

    public struct Result {
        public let eventConnection: AirPlayRTSPConnection
        public let dataPort: Int
        public let controlPort: Int
    }

    /// `requestTarget` is the RTSP request-line target for SETUP/RECORD —
    /// real RTSP methods address a full `rtsp://host/session` URL, unlike
    /// the bare `/pair-verify`-style paths pairing uses. `host` is used to
    /// open the event connection phase 1 requires (same host, different
    /// port) — pass the same host the main `connection` is already
    /// connected to.
    public static func run(
        connection: AirPlayRTSPConnection,
        host: NWEndpoint.Host,
        requestTarget: String,
        sessionUUID: String,
        sharedKey: [UInt8],
        audioFormat: Int = 0x0004_0000, // ALAC 44100/16/2 — confirmed from a public AirPlay2 sender's own doc comment
        samplesPerFrame: Int = 4096, // ALAC's standard frame size
        timingProtocol: String = "PTP",
        timingPort: UInt16? = nil,
        ptpClock: AirPlayPTPClock? = nil,
        streamType: Int = 103,
        localControlPort: UInt16? = nil,
        localDataPort: UInt16? = nil,
        streamConnectionID: Int? = nil,
        recordBeforeStream: Bool = false
    ) async throws -> Result {
        var phase1Body: [String: Any] = [
            "timingProtocol": timingProtocol,
            "osName": "macOS",
            "osVersion": "15.0",
            "name": "SoundCast",
            "sessionUUID": sessionUUID,
            "isRemoteControlOnly": false,
        ]
        if let timingPort {
            phase1Body["timingPort"] = Int(timingPort)
        }
        if let ptpClock {
            let peerInfo = ptpClock.timingPeerInfo
            phase1Body["deviceID"] = ptpClock.deviceID
            phase1Body["macAddress"] = ptpClock.deviceID
            phase1Body["timingPeerInfo"] = peerInfo
            phase1Body["timingPeerList"] = [peerInfo]
            phase1Body["groupUUID"] = sessionUUID
            phase1Body["groupContainsGroupLeader"] = false
        }
        let phase1Data = try PropertyListSerialization.data(fromPropertyList: phase1Body, format: .binary, options: 0)
        let phase1Response = try await connection.send(
            method: "SETUP", path: requestTarget,
            extraHeaders: streamHeaders.merging(["Content-Type": "application/x-apple-binary-plist"]) { _, new in new },
            body: Array(phase1Data)
        )
        guard phase1Response.statusCode == 200 else {
            throw StreamError.unexpectedStatus(phase1Response.statusCode, phase1Response.body)
        }
        guard let phase1Plist = try PropertyListSerialization.propertyList(
            from: Data(phase1Response.body), options: [], format: nil
        ) as? [String: Any] else {
            throw StreamError.malformedResponse
        }
        guard let eventPort = phase1Plist["eventPort"] as? Int else {
            throw StreamError.malformedResponse
        }
        // Confirmed live: RECORD fails with a 500 unless this connection
        // is open first. Nothing is sent over it — its mere presence
        // seems to be what the receiver is waiting for.
        let eventConnection = AirPlayRTSPConnection(host: host, port: NWEndpoint.Port(rawValue: UInt16(eventPort))!)
        try await eventConnection.connect()

        if recordBeforeStream {
            try await record(
                connection: connection,
                requestTarget: requestTarget,
                includeRTPInfo: false
            )
        }

        var streamDict: [String: Any] = [
            "type": streamType,
            "audioFormat": audioFormat,
            "spf": samplesPerFrame,
            "shk": Data(sharedKey),
        ]
        if streamType == 96 {
            streamDict["audioMode"] = "default"
            streamDict["controlPort"] = Int(localControlPort ?? 0)
            streamDict["dataPort"] = Int(localDataPort ?? 0)
            streamDict["ct"] = 2
            streamDict["isMedia"] = true
            streamDict["latencyMax"] = 88_200
            streamDict["latencyMin"] = 11_025
            streamDict["sr"] = 44_100
            streamDict["supportsDynamicStreamID"] = false
            if let streamConnectionID {
                streamDict["streamConnectionID"] = streamConnectionID
            }
        }
        let phase2Body: [String: Any] = ["streams": [streamDict]]
        let phase2Data = try PropertyListSerialization.data(fromPropertyList: phase2Body, format: .binary, options: 0)
        if ProcessInfo.processInfo.environment["DEBUG_AUDIO"] != nil {
            let shkHex = sharedKey.map { String(format: "%02x", $0) }.joined()
            FileHandle.standardError.write("[SETUP DEBUG] shk sent (len=\(sharedKey.count))=\(shkHex)\n".data(using: .utf8)!)
            if let roundTrip = try? PropertyListSerialization.propertyList(from: phase2Data, options: [], format: nil) as? [String: Any],
               let streams = roundTrip["streams"] as? [[String: Any]],
               let shkData = streams.first?["shk"] as? Data {
                FileHandle.standardError.write("[SETUP DEBUG] shk round-tripped through plist (len=\(shkData.count))=\(shkData.map { String(format: "%02x", $0) }.joined())\n".data(using: .utf8)!)
            }
        }
        let phase2Response = try await connection.send(
            method: "SETUP", path: requestTarget,
            extraHeaders: streamHeaders.merging(["Content-Type": "application/x-apple-binary-plist"]) { _, new in new },
            body: Array(phase2Data)
        )
        guard phase2Response.statusCode == 200 else {
            throw StreamError.unexpectedStatus(phase2Response.statusCode, phase2Response.body)
        }
        guard let phase2Plist = try PropertyListSerialization.propertyList(
            from: Data(phase2Response.body), options: [], format: nil
        ) as? [String: Any],
              let streams = phase2Plist["streams"] as? [[String: Any]],
              let firstStream = streams.first else {
            throw StreamError.malformedResponse
        }
        guard let dataPort = (firstStream["dataPort"] as? Int) ?? (firstStream["serverPort"] as? Int) else {
            throw StreamError.malformedResponse
        }
        let controlPort = (firstStream["controlPort"] as? Int) ?? dataPort

        return Result(eventConnection: eventConnection, dataPort: dataPort, controlPort: controlPort)
    }

    /// Tells the receiver how to map audio timestamps to real playback
    /// time — per a real AirPlay 2 *receiver*'s dispatch table, this is
    /// its own RTSP method (not a SET_PARAMETER), and the receiver only
    /// actually reads `rate` and `rtpTime` from the body. `rtpTime`
    /// should be the timestamp of the first audio frame about to be
    /// sent; `rate` is 1.0 for normal playback.
    public static func setRateAnchorTime(connection: AirPlayRTSPConnection, requestTarget: String, rtpTime: UInt32) async throws {
        let body: [String: Any] = ["rate": 1.0, "rtpTime": rtpTime]
        let data = try PropertyListSerialization.data(fromPropertyList: body, format: .binary, options: 0)
        let response = try await connection.send(
            method: "SETRATEANCHORTIME", path: requestTarget,
            extraHeaders: streamHeaders.merging(["Content-Type": "application/x-apple-binary-plist"]) { _, new in new },
            body: Array(data)
        )
        guard response.statusCode == 200 else {
            throw StreamError.unexpectedStatus(response.statusCode, response.body)
        }
    }

    public static func record(
        connection: AirPlayRTSPConnection,
        requestTarget: String,
        includeRTPInfo: Bool = true
    ) async throws {
        let recordHeaders = includeRTPInfo
            ? streamHeaders.merging(["RTP-Info": "seq=1;rtptime=0"]) { _, new in new }
            : streamHeaders
        let response = try await connection.send(method: "RECORD", path: requestTarget, extraHeaders: recordHeaders)
        guard response.statusCode == 200 else {
            throw StreamError.unexpectedStatus(response.statusCode, response.body)
        }
    }
}
