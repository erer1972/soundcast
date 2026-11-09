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

    private func device(id: Any?) -> SoundDevice? {
        guard let id = id as? String else { return nil }
        return (localDevices + airplayDevices + sonosDevices).first { $0.id == id }
    }

    private func perform(_ action: String, _ command: [String: Any]) {
        let value = (command["value"] as? NSNumber)?.doubleValue
        // Rooms and volumes live under the single Casting switch's source;
        // the fallback capture mirrors them.
        switch action {
        case "setCasting":
            if let on = command["on"] as? Bool { setCasting(on) }
        case "toggleDevice":
            if let device = device(id: command["device"]) {
                toggleDevice(device, for: Self.mainSource)
            }
        case "setGain":
            if let device = device(id: command["device"]), let value {
                setGain(for: device, source: Self.mainSource, gain: Float(max(0, min(1, value))))
            }
        case "retry":
            if let id = command["device"] as? String {
                retrySonos(deviceID: id, source: castingSource)
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
        let casting: [String: Any] = [
            "on": isCasting,
            "error": lastErrorBySource[castingSource] ?? "",
            "fallback": fallbackReason ?? "",
            "level": Double(sourceLevels[castingSource] ?? 0),
            "selected": Array(selectedDeviceIDsBySource[Self.mainSource] ?? []),
            "gains": (perDeviceGainBySource[Self.mainSource] ?? [:]).mapValues { Double($0) },
        ]
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
            "casting": casting,
            "groups": groups,
        ]
    }
}
