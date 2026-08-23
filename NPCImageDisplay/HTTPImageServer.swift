import Foundation
import Network

struct HTTPImageServerError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return message
    }
}

final class HTTPImageServer {
    var onImage: ((Data, String, String?) -> Bool)?
    var onClear: ((String?) -> Void)?
    var onStateChange: ((String) -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.npcimagedisplay.http")
    private let port: UInt16
    private var activeConnections: [ObjectIdentifier: HTTPConnection] = [:]

    init(port: UInt16, serviceName: String = "NPC Image Display") throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPImageServerError(message: "Invalid port \(port)")
        }

        self.port = port
        listener = try NWListener(using: .tcp, on: nwPort)
        listener.service = NWListener.Service(name: serviceName, type: "_npc-image._tcp")
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else {
                connection.cancel()
                return
            }

            let httpConnection = HTTPConnection(connection: connection, server: self, queue: self.queue)
            let identifier = ObjectIdentifier(httpConnection)
            self.activeConnections[identifier] = httpConnection
            httpConnection.onComplete = { [weak self] in
                self?.queue.async {
                    self?.activeConnections.removeValue(forKey: identifier)
                }
            }
            httpConnection.start()
        }

        listener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State) {
        let message: String?
        switch state {
        case .ready:
            message = "Listening on port \(port)\nBonjour: _npc-image._tcp"
        case .failed(let error):
            message = "Server failed: \(error.localizedDescription)"
        case .cancelled:
            message = "Server stopped"
        case .waiting(let error):
            message = "Waiting: \(error.localizedDescription)"
        default:
            message = nil
        }

        if let message = message {
            DispatchQueue.main.async {
                self.onStateChange?(message)
            }
        }
    }

    fileprivate func route(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/"):
            completion(.html("""
            <!doctype html>
            <html>
            <head><meta name="viewport" content="width=device-width, initial-scale=1"><title>NPC Image Display</title></head>
            <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#111;color:#eee;padding:24px;">
            <h1>NPC Image Display</h1>
            <p>POST base64 PNG JSON to <code>/image</code>.</p>
            <p><code>{"name":"Goblin","image":"BASE64_PNG_BYTES"}</code></p>
            </body>
            </html>
            """))

        case ("GET", "/health"):
            completion(.json(["ok": true, "port": Int(port)]))

        case ("POST", "/clear"):
            handleClearRequest(request, completion: completion)

        case ("POST", "/image"):
            handleImageRequest(request, completion: completion)

        default:
            completion(.json(["ok": false, "error": "not_found"], status: 404))
        }
    }

    private func handleImageRequest(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
        guard request.body.count <= 28 * 1024 * 1024 else {
            completion(.json(["ok": false, "error": "payload_too_large"], status: 413))
            return
        }

        do {
            let payload = try JSONDecoder().decode(ImagePayload.self, from: request.body)
            guard let encodedImage = payload.encodedImage else {
                completion(.json(["ok": false, "error": "missing_image"], status: 400))
                return
            }

            let cleanedBase64 = encodedImage
                .replacingOccurrences(of: "data:image/png;base64,", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")

            guard let imageData = Data(base64Encoded: cleanedBase64) else {
                completion(.json(["ok": false, "error": "invalid_base64"], status: 400))
                return
            }

            DispatchQueue.main.async {
                let accepted = self.onImage?(imageData, payload.name ?? "", payload.backgroundColor) ?? false
                if accepted {
                    completion(.json(["ok": true, "bytes": imageData.count]))
                } else {
                    completion(.json(["ok": false, "error": "invalid_image"], status: 400))
                }
            }
        } catch {
            completion(.json(["ok": false, "error": "invalid_json"], status: 400))
        }
    }

    private func handleClearRequest(_ request: HTTPRequest, completion: @escaping (HTTPResponse) -> Void) {
        let backgroundColor: String?
        if request.body.isEmpty {
            backgroundColor = nil
        } else if let payload = try? JSONDecoder().decode(ClearPayload.self, from: request.body) {
            backgroundColor = payload.backgroundColor
        } else {
            completion(.json(["ok": false, "error": "invalid_json"], status: 400))
            return
        }

        DispatchQueue.main.async {
            self.onClear?(backgroundColor)
            completion(.json(["ok": true, "cleared": true]))
        }
    }
}

private struct ImagePayload: Decodable {
    let name: String?
    let image: String?
    let pngBase64: String?
    let backgroundColor: String?

    var encodedImage: String? {
        return image ?? pngBase64
    }

    enum CodingKeys: String, CodingKey {
        case name
        case image
        case pngBase64 = "png_base64"
        case backgroundColor = "background_color"
    }
}

private struct ClearPayload: Decodable {
    let backgroundColor: String?

    enum CodingKeys: String, CodingKey {
        case backgroundColor = "background_color"
    }
}

private final class HTTPConnection {
    var onComplete: (() -> Void)?

    private let connection: NWConnection
    private unowned let server: HTTPImageServer
    private let queue: DispatchQueue
    private var buffer = Data()
    private let maxRequestBytes = 30 * 1024 * 1024

    init(connection: NWConnection, server: HTTPImageServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receiveMore()
    }

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data {
                self.buffer.append(data)
            }

            if self.buffer.count > self.maxRequestBytes {
                self.send(.json(["ok": false, "error": "payload_too_large"], status: 413))
                return
            }

            if let request = HTTPRequest(data: self.buffer) {
                self.server.route(request) { [weak self] response in
                    self?.queue.async {
                        self?.send(response)
                    }
                }
                return
            }

            if error != nil || isComplete {
                self.send(.json(["ok": false, "error": "bad_request"], status: 400))
                return
            }

            self.receiveMore()
        }
    }

    private func send(_ response: HTTPResponse) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.onComplete?()
        })
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let valueStart = line.index(after: colon)
            parsedHeaders[key] = line[valueStart...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }

        method = requestParts[0].uppercased()
        path = URLComponents(string: requestParts[1])?.path ?? requestParts[1]
        headers = parsedHeaders
        body = data[bodyStart..<(bodyStart + contentLength)]
    }
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return HTTPResponse(status: status, reason: reasonPhrase(for: status), contentType: "application/json", body: body)
    }

    static func html(_ text: String, status: Int = 200) -> HTTPResponse {
        return HTTPResponse(
            status: status,
            reason: reasonPhrase(for: status),
            contentType: "text/html; charset=utf-8",
            body: Data(text.utf8)
        )
    }

    func serialize() -> Data {
        var response = Data()
        response.appendString("HTTP/1.1 \(status) \(reason)\r\n")
        response.appendString("Content-Type: \(contentType)\r\n")
        response.appendString("Content-Length: \(body.count)\r\n")
        response.appendString("Connection: close\r\n")
        response.appendString("\r\n")
        response.append(body)
        return response
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 413:
            return "Payload Too Large"
        default:
            return "OK"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
