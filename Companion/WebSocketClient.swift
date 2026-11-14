import Foundation

/// WebSocket client for the companion backend.
///
/// Protocol (backend at ws://192.144.154.194:8080):
///   Client -> Server:
///     {"type":"start","format":"pcm16k"}   — before sending audio
///     binary PCM16 16kHz mono chunks       — while recording
///     {"type":"stop"}                      — when the user stops speaking
///     {"type":"text","text":"..."}         — text fallback (treated like a transcript)
///   Server -> Client:
///     {"type":"transcript","text":"..."}   — what the user said (real ASR text)
///     {"type":"reply_text","text":"..."}   — the assistant's reply text
///     binary TTS audio (PCM16 16kHz mono, or mp3)
///     {"type":"done"}                      — end of this turn
///     {"type":"error","message":"..."}     — error, show the message
final class WebSocketClient {
    private static let serverURLString = "ws://192.144.154.194:8080"

    enum Event {
        case transcript(String)
        case replyText(String)
        case audioChunk(Data)
        case turnDone
        case error(String)
    }

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var status: Status = .disconnected {
        didSet { onStatusChange?(status) }
    }
    private var reconnectAttempted = false
    private var isConnecting = false

    /// User-initiated connect (view appear / retry button). Resets the retry budget.
    func connect() {
        reconnectAttempted = false
        doConnect()
    }

    /// Automatic single retry after a drop. Does not reset the retry budget.
    private func reconnect() {
        doConnect()
    }

    private func doConnect() {
        guard task == nil, !isConnecting else { return }
        guard let url = URL(string: Self.serverURLString) else {
            status = .failed("无效的服务器地址")
            return
        }
        isConnecting = true
        status = .connecting
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnecting = false
        status = .connected
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = .disconnected
    }

    var isConnected: Bool {
        task != nil && status == .connected
    }

    func sendStart() {
        sendJSON(["type": "start", "format": "pcm16k"])
    }

    func sendStop() {
        sendJSON(["type": "stop"])
    }

    func sendText(_ text: String) {
        sendJSON(["type": "text", "text": text])
    }

    func sendAudio(_ data: Data) {
        guard let task else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error)
            }
        }
    }

    private func sendJSON(_ dict: [String: String]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleDisconnect(error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    self.onEvent?(.audioChunk(data))
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "transcript":
            if let t = json["text"] as? String { onEvent?(.transcript(t)) }
        case "reply_text":
            if let t = json["text"] as? String { onEvent?(.replyText(t)) }
        case "done":
            onEvent?(.turnDone)
        case "error":
            let m = (json["message"] as? String) ?? "服务器返回了错误"
            onEvent?(.error(m))
        default:
            break
        }
    }

    private func handleDisconnect(_ error: Error) {
        guard task != nil else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if !reconnectAttempted {
            // One automatic retry.
            reconnectAttempted = true
            status = .connecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reconnect()
            }
        } else {
            status = .failed(error.localizedDescription)
        }
    }
}
