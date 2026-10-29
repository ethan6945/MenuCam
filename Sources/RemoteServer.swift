import Foundation
import Network
import Security
import Darwin

private final class HTTPConnection {
    let fd: Int32
    init(fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 5, tv_usec: 0), yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    // shutdown wakes a pending read; close waits until every worker releases this object.
    func cancel() { shutdown(fd, SHUT_RDWR) }
    deinit { close(fd) }
}
private final class HTTPListener {
    let source: DispatchSourceRead
    init(host: String, port: UInt16, queue: DispatchQueue, accept: @escaping (HTTPConnection) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); throw POSIXError(.EINVAL) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 16) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO); close(fd); throw error
        }
        fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                fcntl(client, F_SETFL, 0)
                accept(HTTPConnection(fd: client))
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

/// No wildcard binding, port forwarding, Serve or Funnel. Listens only on
/// IPv4 Tailscale utun interfaces and loopback. All recorder access stays on the main queue.
final class RemoteServer: ObservableObject {
    let port: UInt16
    init(port: UInt16 = 8765) { self.port = port }
    @Published private(set) var addresses: [String] = []
    @Published private(set) var status = "Starting"
    private let queue = DispatchQueue(label: "MenuCam.web")
    private var listeners: [String: HTTPListener] = [:]
    private var clients: [UUID: HTTPConnection] = [:]
    private var refresh: DispatchSourceTimer?
    private var token = ""
    private var failures = 0
    private var window = Date()
    private var handler: ((String) -> (Int, [String: Any]))?
    var snapshotHandler: ((@escaping (Int, Data?) -> Void) -> Void)?
    var quitHandler: (() -> Void)?
    private var started = false
    var localAddress: String? { addresses.first { $0.contains("127.0.0.1") } }
    var localURL: URL? { localAddress.flatMap { token.isEmpty ? nil : URL(string: $0 + "#key=" + token) } }
    var accessKey: String { token }
    var controlAddress: String? { addresses.filter { !$0.contains("127.0.0.1") }.sorted().first }
    var controlURL: URL? {
        guard let address = controlAddress, !token.isEmpty else { return nil }
        return URL(string: address + "#key=" + token)
    }
    static func tailAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = [], node = first
        while let item = node {
            defer { node = item.pointee.ifa_next }
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: item.pointee.ifa_name).hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host), parts = ip.split(separator: ".").compactMap { Int($0) }
                if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { result.append(ip) }
            }
        }
        return Array(Set(result)).sorted()
    }
    static func loadKey(directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("remote-key")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let value = try String(contentsOf: file, encoding: .utf8)
            guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw NSError(domain: "MenuCam", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid access key file"] ) }
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NSError(domain: "MenuCam", code: 11) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(value.utf8).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return value
    }
    func start(directory: URL? = nil, handler: @escaping (String) -> (Int, [String: Any])) {
        guard !started else { return }
        self.handler = handler
        do {
            token = try Self.loadKey(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuCam", isDirectory: true))
        } catch { status = "Remote server could not start: \(error.localizedDescription)"; return }
        started = true
        queue.async {
            self.updateListeners()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.updateListeners() }
            self.refresh = timer; timer.resume()
        }
    }
    private func updateListeners() {
        let tails = Self.tailAddresses()
        let targets = Set(tails + ["127.0.0.1"])
        DispatchQueue.main.async { self.status = tails.isEmpty ? "Local ready · Waiting for Tailscale" : "Tailscale connected" }
        for host in Array(listeners.keys) where !targets.contains(host) {
            listeners.removeValue(forKey: host)?.cancel()
            DispatchQueue.main.async {
                self.addresses.removeAll { $0 == "http://\(host):\(self.port)" }
                self.status = self.controlAddress == nil ? "Local ready · Waiting for Tailscale" : "Tailscale connected"
            }
        }
        for host in targets where listeners[host] == nil {
            do {
                let listener = try HTTPListener(host: host, port: self.port, queue: queue) { [weak self] connection in self?.accept(connection) }
                listeners[host] = listener
                DispatchQueue.main.async {
                    let url = "http://\(host):\(self.port)"
                    if !self.addresses.contains(url) { self.addresses.append(url); self.addresses.sort() }
                    self.status = self.controlAddress == nil ? "Local ready · Waiting for Tailscale" : "Tailscale connected"
                }
            } catch { DispatchQueue.main.async { self.status = "Port \(self.port) cannot listen: \(error.localizedDescription)" } }
        }
    }
    private func accept(_ connection: HTTPConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in self?.clients.removeValue(forKey: id)?.cancel() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data(), chunk = [UInt8](repeating: 0, count: 8192)
            while buffer.count <= 16384 {
                let count = recv(connection.fd, &chunk, chunk.count, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk.prefix(count))
                if buffer.count > 16384 {
                    self?.queue.async { [weak self] in self?.respond(connection, id, 413, "Too large") }
                    return
                }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let request = end.upperBound == buffer.endIndex ? String(data: buffer, encoding: .utf8) : nil
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        if let request { self.route(request, connection, id) }
                        else { self.respond(connection, id, 400, "Invalid request") }
                    }
                    return
                }
            }
            self?.queue.async { [weak self] in
                connection.cancel(); self?.clients.removeValue(forKey: id)
            }
        }
    }
    private func route(_ request: String, _ connection: HTTPConnection, _ id: UUID) {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count == 3, first[2] == "HTTP/1.1" else { respond(connection, id, 400, "Bad request"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { respond(connection, id, 400, "Bad header"); return }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil else { respond(connection, id, 400, "Duplicate header"); return }
            headers[key] = value
        }
        guard let host = headers["host"], headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else { respond(connection, id, 400, "Bad framing"); return }
        if let origin = headers["origin"], origin != "http://\(host)" { respond(connection, id, 403, "Origin denied"); return }
        if first[0] == "GET" {
            let icon: (Data, String)?
            switch first[1] {
            case "/favicon.ico", "/favicon-v1.5.3.ico": icon = (WebIcon.favicon, "image/x-icon")
            case "/favicon.png": icon = (WebIcon.smallPNG, "image/png")
            case "/apple-touch-icon.png", "/apple-touch-icon-v1.5.3.png": icon = (WebIcon.png, "image/png")
            default: icon = nil
            }
            if let icon { respondData(connection, id, 200, icon.0, type: icon.1); return }
        }
        if first[0] == "GET", first[1] == "/" { respond(connection, id, 200, Self.page, type: "text/html; charset=utf-8"); return }
        guard ["/api/status", "/api/start", "/api/stop", "/api/snapshot", "/api/quit"].contains(first[1]) else { respond(connection, id, 404, "Not found"); return }
        if Date().timeIntervalSince(window) > 60 { failures = 0; window = Date() }
        guard failures < 60 else { respond(connection, id, 429, "Try again later"); return }
        let supplied = Array((headers["authorization"] ?? "").utf8), expected = Array("Bearer \(token)".utf8)
        var difference = supplied.count ^ expected.count
        for i in expected.indices { difference |= Int(expected[i] ^ (i < supplied.count ? supplied[i] : 0)) }
        guard difference == 0 else { failures += 1; respond(connection, id, 401, "Unauthorized"); return }
        guard first[0] == (["/api/status", "/api/snapshot"].contains(first[1]) ? "GET" : "POST") else { respond(connection, id, 405, "Method denied"); return }
        if first[1] == "/api/quit" {
            respondData(connection, id, 200, Data("{\"quitting\":true}".utf8), type: "application/json") {
                DispatchQueue.main.async { self.quitHandler?() }
            }
            return
        }
        if first[1] == "/api/snapshot" {
            DispatchQueue.main.async {
                guard let handler = self.snapshotHandler else { self.queue.async { self.respond(connection, id, 503, "Snapshot unavailable") }; return }
                handler { code, data in
                    self.queue.async {
                        if code == 200, let data { self.respondData(connection, id, 200, data, type: "image/jpeg") }
                        else { self.respond(connection, id, code, code == 403 ? "Allow camera access on the Mac" : code == 409 ? "Busy. Please wait." : "Unable to capture a photo. Please retry.") }
                    }
                }
            }
            return
        }
        DispatchQueue.main.async {
            let (code, state) = self.handler?(first[1]) ?? (503, ["error": "Unavailable"])
            let body = (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
            self.queue.async { self.respond(connection, id, code, String(decoding: body, as: UTF8.self), type: "application/json") }
        }
    }
    private func respond(_ connection: HTTPConnection, _ id: UUID, _ code: Int, _ body: String, type: String = "text/plain; charset=utf-8") {
        respondData(connection, id, code, Data(body.utf8), type: type)
    }
    private func respondData(_ connection: HTTPConnection, _ id: UUID, _ code: Int, _ data: Data, type: String, completion: (() -> Void)? = nil) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; img-src 'self' data:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        let response = Data(head.utf8) + data
        DispatchQueue.global(qos: .utility).async { [weak self] in
            response.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = send(connection.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
            connection.cancel()
            completion?()
            self?.queue.async { [weak self] in self?.clients.removeValue(forKey: id) }
        }
    }
    static let page = #"""
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>MenuCam</title><meta name="menucam-version" content="1.6.0"><link rel="icon" type="image/x-icon" sizes="16x16 32x32 48x48" href="/favicon-v1.5.3.ico"><link rel="shortcut icon" href="/favicon-v1.5.3.ico"><link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon-v1.5.3.png"><meta name="apple-mobile-web-app-title" content="MenuCam">
<style>:root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;background:light-dark(#f2f4f6,#16191d);font:16px -apple-system,BlinkMacSystemFont,sans-serif;color:light-dark(#192126,#eef3f4)}main{max-width:420px;margin:auto;padding:32px 20px}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}h1{font-size:22px;margin:0}#quit{width:auto;min-height:32px;padding:6px 12px;font-size:12px;background:transparent;color:inherit;border:1px solid #83919a;border-radius:8px}.card{border-radius:14px;padding:24px;background:light-dark(white,#23282e);text-align:center}#phase,#notice{color:light-dark(#57636c,#a9b5bc);font-size:14px}#clock{cursor:pointer;touch-action:manipulation;user-select:none;-webkit-user-select:none;font:42px ui-monospace,monospace;font-variant-numeric:tabular-nums;margin:28px 0}button{font:600 17px -apple-system,sans-serif;border-radius:10px;padding:16px;width:100%;min-height:52px;border:0;background:#109c96;color:white;cursor:pointer}button:disabled{opacity:.45;cursor:default}.stop{background:#d54949}#message{white-space:pre-wrap;font-size:13px;color:light-dark(#57636c,#a9b5bc);overflow-wrap:anywhere;text-align:left}#message:empty{display:none}#notice{text-align:center;line-height:1.5}[hidden]{display:none!important}#shot{width:100%;max-height:65vh;object-fit:contain;border-radius:8px;cursor:pointer;margin:16px 0;touch-action:manipulation}#photoStatus{font-size:13px;text-align:center;padding:16px 0;color:light-dark(#57636c,#a9b5bc)}#login{text-align:left}#login h2{font-size:18px;margin:0 0 12px}.authHelp,#authError{font-size:13px;line-height:1.5;color:light-dark(#57636c,#a9b5bc)}#login label{font-size:13px}#authKey{display:block;width:100%;min-height:48px;margin:8px 0 16px;padding:12px;border-radius:8px;border:1px solid #83919a;background:transparent;color:inherit;font:16px -apple-system,sans-serif}#authError:empty{display:none}</style>
<main><header><h1>MenuCam</h1><button id="quit" hidden title="Save recording and quit MenuCam">Quit</button></header><section id="login" class="card"><form id="authForm"><h2>Device Authorization</h2><p class="authHelp">First time here? Paste the full control link or access key copied from your Mac.</p><label for="authKey">Control link or access key</label><input id="authKey" type="password" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="Paste control link or access key" required><button id="authorize" type="submit">Authorize &amp; Connect</button><p id="authError" role="status"></p></form></section><section id="control" class="card" hidden><span id="phase" role="status">Connecting…</span><div id="clock" role="button" tabindex="0" aria-label="Triple-tap for a current photo">00:00:00</div><p id="photoStatus" role="status" hidden></p><img id="shot" alt="Current camera photo" role="button" tabindex="0" aria-label="Dismiss photo and show timer" hidden><button id="action" disabled>Start Recording</button><p id="message"></p></section><p id="notice" role="status"></p></main>
<script>
const $=id=>document.getElementById(id);let token='',state=null,polling=false,pending=false,quitting=false;
const incoming=new URLSearchParams(location.hash.slice(1)).get('key');
try{token=incoming||localStorage.getItem('menucam-key')||''}catch(e){token=incoming||''}
function showAuthorization(message=''){state=null;$('quit').hidden=true;$('control').hidden=true;$('login').hidden=false;$('authError').textContent=message;$('notice').textContent='';$('authorize').disabled=false}
function rememberAuthorization(){try{localStorage.setItem('menucam-key',token)}catch(e){}if(new URLSearchParams(location.hash.slice(1)).get('key')!==token)history.replaceState(null,'',location.pathname+location.search+'#key='+encodeURIComponent(token));$('authKey').value='';$('authError').textContent='';$('login').hidden=true;$('control').hidden=false}
$('authForm').onsubmit=async event=>{
 event.preventDefault();const value=$('authKey').value.trim();let candidate=value;
 try{const link=new URL(value);candidate=new URLSearchParams(link.hash.slice(1)).get('key')||''}catch(e){}
 if(!/^[a-fA-F0-9]{64}$/.test(candidate)){showAuthorization('Enter a full control link or a 64-character access key.');return}
 token=candidate;$('authorize').disabled=true;$('authError').textContent='Verifying…';
 try{const status=await request('status');rememberAuthorization();render(status)}catch(e){token='';showAuthorization(e.status===401?'Invalid key. Copy the control link again.':e.message)}finally{$('authorize').disabled=false}
};
async function request(path,method='GET'){const r=await fetch('/api/'+path,{method,headers:{Authorization:'Bearer '+token},cache:'no-store',signal:AbortSignal.timeout(4000)});if(!r.ok){const error=Error(r.status===401?'Authorization required. Copy the full control link from your Mac.':r.status===409?'Busy. Please wait.':'Unable to connect');error.status=r.status;throw error}return r.json()}
function render(s){if(quitting)return;state=s;$('quit').hidden=false;$('quit').disabled=pending;$('login').hidden=true;$('control').hidden=false;$('phase').textContent=s.phase;$('clock').textContent=s.clock;$('message').textContent=s.message;$('action').textContent=s.busy?s.phase+'…':s.recording?'Stop & Save':'Start Recording';$('action').className=s.recording?'stop':'';$('action').disabled=s.busy||pending;$('notice').textContent=''}
async function poll(){if(quitting)return;if(!token){if($('login').hidden)showAuthorization();return}if(polling||pending)return;polling=true;try{const status=await request('status');rememberAuthorization();render(status)}catch(e){state=null;$('action').disabled=true;if(e.status===401){token='';showAuthorization('Authorization expired. Copy the control link again.')}else if(!$('login').hidden){showAuthorization(e.message)}else{$('phase').textContent='Disconnected';$('notice').textContent=e.message}}finally{polling=false}}
let taps=0,lastTap=0,photoBusy=false,photoVisible=false,photoController=null,photoGeneration=0;
function hidePhoto(){
 photoGeneration++;if(photoController)photoController.abort();photoController=null;photoBusy=false;photoVisible=false;
 $('shot').onload=null;$('shot').onerror=null;$('shot').hidden=true;$('shot').removeAttribute('src');$('photoStatus').hidden=true;$('photoStatus').textContent='';$('clock').hidden=false;
}
function photoDataURL(blob){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Unable to read the photo. Please retry.'));reader.readAsDataURL(blob)})}
async function takePhoto(){
 if(photoBusy)return;
 if(!state||state.busy){$('photoStatus').hidden=false;$('photoStatus').textContent='Busy. Please wait.';return}
 hidePhoto();const generation=photoGeneration;photoBusy=true;$('clock').hidden=true;$('photoStatus').hidden=false;$('photoStatus').textContent='Capturing current photo…';
 const controller=new AbortController();photoController=controller;const deadline=setTimeout(()=>controller.abort(),9000);
 try{
  const r=await fetch('/api/snapshot',{headers:{Authorization:'Bearer '+token},cache:'no-store',signal:controller.signal});
  if(!r.ok)throw Error(r.status===403?'Allow camera access on the Mac':r.status===409?'Busy. Please wait.':r.status===401?'Copy the control link from your Mac again.':'Unable to capture a photo. Please retry.');
  const image=await r.blob();if(!image.size)throw Error('Empty photo. Please retry.');
  const dataURL=await photoDataURL(image);if(generation!==photoGeneration)return;
  await new Promise((resolve,reject)=>{
   const shot=$('shot'),timer=setTimeout(()=>finish(Error('Photo loading timed out. Please retry.')),2000);
   function finish(error){clearTimeout(timer);shot.onload=null;shot.onerror=null;error?reject(error):resolve()}
   shot.onload=()=>finish();shot.onerror=()=>finish(Error('Unable to display the photo. Please retry.'));shot.src=dataURL;
   if(shot.complete){shot.naturalWidth?finish():finish(Error('Unable to display the photo. Please retry.'))}
  });
  if(generation===photoGeneration){$('shot').hidden=false;$('photoStatus').hidden=true;photoVisible=true}
 }catch(e){if(generation===photoGeneration){$('shot').hidden=true;$('shot').removeAttribute('src');$('clock').hidden=false;$('photoStatus').hidden=false;$('photoStatus').textContent=e.name==='AbortError'?'Capture timed out. Triple-tap the timer to retry.':e.message}}
 finally{clearTimeout(deadline);if(generation===photoGeneration){photoBusy=false;photoController=null}}
}
function tapClock(){const now=performance.now();taps=now-lastTap<450?taps+1:1;lastTap=now;if(taps===3){taps=0;takePhoto()}}
$('clock').onclick=tapClock;$('clock').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();tapClock()}};
$('shot').onclick=hidePhoto;$('shot').onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();hidePhoto()}};
window.addEventListener('pagehide',hidePhoto);
$('quit').onclick=async()=>{
 if(pending||quitting)return;
 if(!confirm('Quit MenuCam? Any active recording will be saved. Reopen the Mac app to reconnect.'))return;
 pending=true;$('quit').disabled=true;$('action').disabled=true;
 try{await request('quit','POST');quitting=true;hidePhoto();$('phase').textContent='Quitting';$('notice').textContent='MenuCam is saving any active recording and shutting down. Reopen the Mac app to reconnect.'}
 catch(e){$('notice').textContent=e.message;$('quit').disabled=false}
 finally{pending=false;if(!quitting)poll()}
};
$('action').onclick=async()=>{if(!state||pending)return;const command=state.recording?'stop':'start';pending=true;$('action').disabled=true;try{render(await request(command,'POST'))}catch(e){$('notice').textContent=e.message}finally{pending=false;poll()}};poll();setInterval(poll,1000);document.addEventListener('visibilitychange',()=>{if(!document.hidden)poll()});
</script></html>
"""#
}
