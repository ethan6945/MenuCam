import Foundation

@main struct RemoteTests {
    static func main() {
        let directory = URL(fileURLWithPath: "/private/tmp/menucam-remote-test-\(UUID().uuidString)")
        do {
            let key = try RemoteServer.loadKey(directory: directory)
            let loaded = try RemoteServer.loadKey(directory: directory)
            precondition(key.count == 64 && key == loaded)
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("remote-key").path)
            precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        } catch { fatalError("Key persistence: \(error)") }
        guard let host = RemoteServer.tailAddresses().first else { fatalError("Connect Tailscale before running the remote integration test") }
        let server = RemoteServer(port: 18765)
        var recording = false, transitions = 0
        server.snapshotHandler = { completion in completion(recording ? 200 : 409, recording ? Data([0xff, 0xd8, 0xff, 0xd9]) : nil) }
        server.start(directory: directory) { path in
            if path == "/api/start", !recording { recording = true; transitions += 1 }
            if path == "/api/stop", recording { recording = false; transitions += 1 }
            return (200, ["recording": recording, "busy": false, "clock": "00:00:05", "phase": recording ? "录制中" : "待机", "elapsed": 5, "message": ""])
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            func check(_ path: String, _ method: String = "GET", auth: Bool = false, origin: String? = nil, code: Int = 200) -> Data {
                let semaphore = DispatchSemaphore(value: 0)
                var req = URLRequest(url: URL(string: "http://\(host):18765\(path)")!)
                req.httpMethod = method
                if auth { req.setValue("Bearer \(server.accessKey)", forHTTPHeaderField: "Authorization") }
                if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
                var body = Data()
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [:]
                URLSession(configuration: config).dataTask(with: req) { data, response, error in
                    precondition(error == nil, "Network: \(String(describing: error))")
                    precondition((response as? HTTPURLResponse)?.statusCode == code, "\(path) expected \(code), got \(String(describing: response))")
                    precondition((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
                    body = data ?? Data(); semaphore.signal()
                }.resume()
                precondition(semaphore.wait(timeout: .now() + 8) == .success)
                return body
            }
            let page = String(decoding: check("/"), as: UTF8.self)
            precondition(!page.contains("id=\"login\"") && !page.contains("id=\"key\""))
            precondition(page.contains("location.hash") && page.contains("localStorage"))
            for icon in ["/favicon.ico", "/favicon-v1.5.3.ico"] { precondition(check(icon) == WebIcon.favicon) }
            precondition(check("/favicon.png") == WebIcon.smallPNG)
            precondition(check("/apple-touch-icon-v1.5.3.png") == WebIcon.png)
            precondition(check("/apple-touch-icon.png") == WebIcon.png)
            precondition(Array(WebIcon.favicon.prefix(4)) == [0, 0, 1, 0])
            precondition(page.contains("rel=\"icon\"") && page.contains("rel=\"apple-touch-icon\""))
            _ = check("/api/status", code: 401)
            _ = check("/api/start", "POST", code: 401)
            _ = check("/api/snapshot", code: 401)
            _ = check("/api/snapshot", auth: true, code: 409)
            _ = check("/api/snapshot", "POST", auth: true, code: 405)
            _ = check("/api/status", auth: true, origin: "http://evil.example", code: 403)
            _ = check("/api/start", auth: true, code: 405)
            let start = check("/api/start", "POST", auth: true)
            precondition((try! JSONSerialization.jsonObject(with: start) as! [String: Any])["recording"] as? Bool == true)
            precondition(check("/api/snapshot", auth: true) == Data([0xff, 0xd8, 0xff, 0xd9]))
            _ = check("/api/start", "POST", auth: true)
            let state = check("/api/status", auth: true)
            precondition((try! JSONSerialization.jsonObject(with: state) as! [String: Any])["elapsed"] as? Int == 5)
            _ = check("/api/stop", "POST", auth: true)
            _ = check("/api/stop", "POST", auth: true)
            _ = check("/unknown", auth: true, code: 404)
            DispatchQueue.main.async {
                precondition(transitions == 2)
                precondition(server.controlURL?.fragment == "key=" + server.accessKey)
                precondition(server.controlAddress == "http://\(host):18765")
                precondition(server.addresses.allSatisfy { $0.hasPrefix("http://100.") })
                try? FileManager.default.removeItem(at: directory)
                print("PASS: persistent private key, authentication, origin, methods, start/stop idempotence, live state, response headers and restricted addresses")
                exit(0)
            }
        }
        RunLoop.main.run()
    }
}
