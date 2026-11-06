import Foundation
import Network

/// AirPlay RTSP SETUP (two phases) and RECORD — establishes the audio
/// stream after pair-verify's encrypted channel is up.
///
/// **Verified end-to-end against a real Apple TV** (design doc §12.5):
/// SETUP phase 1, SETUP phase 2 (requesting stream `type=103`,
/// "buffered" — a plain TCP data port instead of UDP/RTP, which avoids
/// implementing PTP entirely), and RECORD all succeeded for real.
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
/// Still unconfirmed: what the event connection is actually *for*
/// (just establishing presence, or does the receiver send something
/// over it that matters once real audio is flowing) and the exact
/// framing/encryption of the `dataPort` audio stream itself (the `shk`
/// 32-byte key is sent but nothing has been decrypted/encrypted with
/// it yet — no audio has been sent).
public enum AirPlayStreamSetup {
    public enum StreamError: Error {
        case malformedResponse
        case unexpectedStatus(Int, [UInt8])
    }

    /// Headers real AirPlay senders include on every RTSP request past
    /// pairing (SETUP, RECORD, SET_PARAMETER, ...), used for remote-
    /// control device matching — commonly documented as required by
    /// receivers even when remote control itself isn't used.
    static let streamHeaders: [String: String] = [
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
        sharedKey: [UInt8]
    ) async throws -> Result {
        let phase1Body: [String: Any] = [
            "timingProtocol": "PTP",
            "osName": "macOS",
            "osVersion": "15.0",
            "name": "SoundCast",
            "sessionUUID": sessionUUID,
            "isRemoteControlOnly": false,
        ]
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

        let streamDict: [String: Any] = [
            "type": 103, // "buffered" — TCP audio channel, no PTP needed
            "audioFormat": 0x400000, // AAC-LC 44.1kHz stereo
            "spf": 1024, // samples per AAC-LC frame
            "shk": Data(sharedKey),
        ]
        let phase2Body: [String: Any] = ["streams": [streamDict]]
        let phase2Data = try PropertyListSerialization.data(fromPropertyList: phase2Body, format: .binary, options: 0)
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
              let firstStream = streams.first,
              let dataPort = firstStream["dataPort"] as? Int,
              let controlPort = firstStream["controlPort"] as? Int else {
            throw StreamError.malformedResponse
        }

        return Result(eventConnection: eventConnection, dataPort: dataPort, controlPort: controlPort)
    }

    public static func record(connection: AirPlayRTSPConnection, requestTarget: String) async throws {
        let recordHeaders = streamHeaders.merging(["RTP-Info": "seq=1;rtptime=0"]) { _, new in new }
        let response = try await connection.send(method: "RECORD", path: requestTarget, extraHeaders: recordHeaders)
        guard response.statusCode == 200 else {
            throw StreamError.unexpectedStatus(response.statusCode, response.body)
        }
    }
}
