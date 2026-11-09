import Foundation
import SoundCastCore

/// The web control page's API: GET / (the page), GET /api/state, and
/// POST /api/action with a small JSON command. Everything runs on the main
/// actor against the same AppState the menu uses.
extension AppState {
    func startWebControl() {
        let server = WebControlServer { [weak self] request in
            await MainActor.run { self?.handleWeb(request) ?? WebResponse(status: 503) }
        }
        do {
            try server.start()
            webControl = server
            webControlAddress = WebControlServer.address
            NSLog("[SoundCast][Web] control page at \(WebControlServer.address)")
        } catch {
            NSLog("[SoundCast][Web] could not start: \(error)")
        }
    }

    func handleWeb(_ request: WebRequest) -> WebResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return WebResponse(contentType: "text/html; charset=utf-8", body: Data(WebControlPage.html.utf8))
        case ("GET", "/api/state"):
            return json(webState())
        case ("POST", "/api/action"):
            guard let command = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let action = command["action"] as? String else {
                return WebResponse(status: 400)
            }
            perform(action, command)
            return json(webState())
        default:
            return WebResponse(status: 404)
        }
    }

    private func json(_ object: [String: Any]) -> WebResponse {
        WebResponse(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    private func source(webID: Any?) -> CastSource? {
        guard let id = webID as? String else { return nil }
        return Self.allSources.first { $0.webID == id }
    }

    private func device(id: Any?) -> SoundDevice? {
        guard let id = id as? String else { return nil }
        return (localDevices + airplayDevices + sonosDevices).first { $0.id == id }
    }

    private func perform(_ action: String, _ command: [String: Any]) {
        let value = (command["value"] as? NSNumber)?.doubleValue
        switch action {
        case "setActive":
            if let source = source(webID: command["source"]), let on = command["on"] as? Bool {
                setActive(source, on: on)
            }
        case "toggleDevice":
            if let source = source(webID: command["source"]), let device = device(id: command["device"]) {
                toggleDevice(device, for: source)
            }
        case "setGain":
            if let source = source(webID: command["source"]), let device = device(id: command["device"]), let value {
                setGain(for: device, source: source, gain: Float(max(0, min(1, value))))
            }
        case "retry":
            if let source = source(webID: command["source"]), let id = command["device"] as? String {
                retrySonos(deviceID: id, source: source)
            }
        case "setMaster":
            if let value { setMasterVolume(Float(max(0, min(1, value)))) }
        case "setAirPlaySync":
            if let value { setSyncOffset(milliseconds: value) }
        case "setVideoSync":
            if let value { setVideoSync(milliseconds: value) }
        case "calibrate":
            calibrateSync()
        default:
            break
        }
    }

    private func webState() -> [String: Any] {
        let sources: [[String: Any]] = Self.allSources.map { source in
            let gains = (perDeviceGainBySource[source] ?? [:]).mapValues { Double($0) }
            return [
                "id": source.webID,
                "name": source.displayName,
                "active": isActive(source),
                "error": lastErrorBySource[source] ?? "",
                "level": Double(sourceLevels[source] ?? 0),
                "selected": Array(selectedDeviceIDsBySource[source] ?? []),
                "gains": gains,
            ]
        }
        let groups: [[String: Any]] = groupedDevices.filter { !$0.1.isEmpty }.map { category, devices in
            [
                "name": category.rawValue,
                "devices": devices.map { device -> [String: Any] in
                    [
                        "id": device.id,
                        "name": device.name,
                        "status": airplayStatus[device.id] ?? sonosStatus[device.id] ?? "",
                        "unpaired": unpairedAirPlayDevices.contains(device.id),
                    ]
                },
            ]
        }
        return [
            "mac": Host.current().localizedName ?? "Mac",
            "master": Double(masterVolume),
            "airplaySync": syncOffsetMilliseconds,
            "videoSync": videoSyncMilliseconds,
            "calibrating": isCalibrating,
            "calibrationStatus": calibrationStatus ?? "",
            "sources": sources,
            "groups": groups,
        ]
    }
}

extension AppState.CastSource {
    /// Stable id for the web API.
    var webID: String {
        switch self {
        case .globalTap: return "everything"
        case .virtualDevice(let preset): return preset.deviceUID
        }
    }
}
