import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }

    let id = UUID()
    let role: Role
    var text: String
}

/// One selectable TTS voice from the backend.
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Owns the WebSocket + audio plumbing and the chat state for ContentView.
final class ChatViewModel: ObservableObject {
    static let voicesURL = URL(string: "http://192.144.154.194:8080/voices")
    static let defaultVoiceId = "tongtong"
    private static let selectedVoiceKey = "companion.selectedVoiceId"

    @Published var messages: [ChatMessage] = []
    @Published var connectionStatus: WebSocketClient.Status = .disconnected
    @Published var isRecording = false
    @Published var isWaitingReply = false
    @Published var isSpeaking = false
    @Published var micDenied = false
    @Published var inputText = ""

    /// Voices from the backend; falls back to the default when the fetch fails.
    @Published var voices: [VoiceOption] = [VoiceOption(id: defaultVoiceId, name: defaultVoiceId)]
    /// Persisted across launches.
    @Published var selectedVoiceId: String = UserDefaults.standard.string(forKey: selectedVoiceKey) ?? defaultVoiceId {
        didSet {
            UserDefaults.standard.set(selectedVoiceId, forKey: Self.selectedVoiceKey)
        }
    }

    private let socket = WebSocketClient()
    private let audio = AudioManager()
    private var wantsRecording = false

    init() {
        socket.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.connectionStatus = status }
        }
        socket.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        audio.onAudioChunk = { [weak self] data in
            self?.socket.sendAudio(data)
        }
    }

    var statusText: String {
        switch connectionStatus {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        case .failed(let message): return "连接失败：\(message)"
        }
    }

    var isConnected: Bool { connectionStatus == .connected }

    func onAppear() {
        audio.configureSession()
        socket.connect()
        fetchVoices()
    }

    // MARK: - Voices

    /// GET /voices from the backend. Any failure keeps the built-in default.
    func fetchVoices() {
        guard let url = Self.voicesURL else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["voices"] as? [[String: Any]] else { return }
            let fetched: [VoiceOption] = list.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let name = (item["name"] as? String) ?? id
                return VoiceOption(id: id, name: name)
            }
            guard !fetched.isEmpty else { return }
            DispatchQueue.main.async {
                self.voices = fetched
                // Keep the user's choice when it is still offered; otherwise
                // fall back to the default voice (or the first listed voice).
                if !fetched.contains(where: { $0.id == self.selectedVoiceId }) {
                    self.selectedVoiceId = fetched.contains(where: { $0.id == Self.defaultVoiceId })
                        ? Self.defaultVoiceId
                        : fetched[0].id
                }
            }
        }.resume()
    }

    // MARK: - Hold to talk

    func startTalking() {
        guard !isRecording else { return }
        wantsRecording = true
        if !socket.isConnected {
            socket.connect()
        }
        // Permission first; the engine is never touched before it is granted.
        audio.requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard self.wantsRecording, granted else {
                if !granted { self.micDenied = true }
                return
            }
            guard self.audio.startRecording() else {
                self.messages.append(ChatMessage(role: .error, text: "录音启动失败，请重试"))
                return
            }
            self.isSpeaking = false
            self.socket.sendStart(voice: self.selectedVoiceId)
            self.isRecording = true
        }
    }

    func stopTalking() {
        wantsRecording = false
        guard isRecording else { return }
        isRecording = false
        audio.stopRecording()
        socket.sendStop()
        isWaitingReply = true
    }

    // MARK: - Text fallback

    func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        messages.append(ChatMessage(role: .user, text: text))
        if !socket.isConnected {
            socket.connect()
        }
        isSpeaking = false
        socket.sendText(text)
        isWaitingReply = true
    }

    // MARK: - Server events

    private func handle(_ event: WebSocketClient.Event) {
        switch event {
        case .transcript(let text):
            messages.append(ChatMessage(role: .user, text: text))
        case .replyText(let text):
            isWaitingReply = false
            messages.append(ChatMessage(role: .assistant, text: text))
        case .audioChunk(let data):
            isSpeaking = true
            audio.playAudioChunk(data)
        case .turnDone:
            isWaitingReply = false
            isSpeaking = false
            audio.finishPlayback()
        case .error(let message):
            isWaitingReply = false
            isSpeaking = false
            messages.append(ChatMessage(role: .error, text: message))
        }
    }
}
