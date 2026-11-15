import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }

    let id = UUID()
    let role: Role
    var text: String
}

/// How the user talks to the companion.
/// - realtime: tap once to start listening, tap again to stop and send.
/// - holdToTalk: press and hold to talk, release to send (default).
enum InputMode: String, CaseIterable {
    case realtime = "realtime"
    case holdToTalk = "hold"

    var label: String {
        switch self {
        case .realtime: return "实时对话"
        case .holdToTalk: return "长按说话"
        }
    }
}

/// Owns the WebSocket + audio plumbing and the chat state for ContentView.
/// NOTE: No voice selection — the backend is GLM-4-Voice end-to-end with a
/// fixed voice, so the client sends no "voice" field in the start message.
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionStatus: WebSocketClient.Status = .disconnected
    @Published var isRecording = false
    @Published var isWaitingReply = false
    @Published var isSpeaking = false
    @Published var micDenied = false
    @Published var inputText = ""
    @Published var inputMode: InputMode = .holdToTalk {
        didSet {
            UserDefaults.standard.set(inputMode.rawValue, forKey: "companion.inputMode")
        }
    }

    private let socket = WebSocketClient()
    private let audio = AudioManager()
    private var wantsRecording = false

    init() {
        if let raw = UserDefaults.standard.string(forKey: "companion.inputMode"),
           let saved = InputMode(rawValue: raw) {
            inputMode = saved
        }
        socket.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.connectionStatus = status }
        }
        socket.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        audio.onAudioChunk = { [weak self] data in
            self?.socket.sendAudio(data)
        }
        audio.onPlaybackFinished = { [weak self] in
            DispatchQueue.main.async { self?.isSpeaking = false }
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
    }

    // MARK: - Voice input

    /// Real-time mode: tap to start listening, tap again to stop and send.
    func toggleTalking() {
        if isRecording {
            stopTalking()
        } else {
            startTalking()
        }
    }

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
            self.socket.sendStart()
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
            // If buffered WAV/mp3 audio just started playing, keep the
            // speaking state until onPlaybackFinished fires; otherwise
            // (PCM path) the audio is already done.
            let buffered = audio.finishPlayback()
            if !buffered {
                isSpeaking = false
            }
        case .error(let message):
            isWaitingReply = false
            isSpeaking = false
            audio.stopPlayback()
            messages.append(ChatMessage(role: .error, text: message))
        }
    }
}
