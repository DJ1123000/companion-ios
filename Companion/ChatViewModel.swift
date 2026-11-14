import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, error }

    let id = UUID()
    let role: Role
    var text: String
}

/// Owns the WebSocket + audio plumbing and the chat state for ContentView.
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionStatus: WebSocketClient.Status = .disconnected
    @Published var isRecording = false
    @Published var isWaitingReply = false
    @Published var micDenied = false
    @Published var inputText = ""

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
    }

    // MARK: - Hold to talk

    func startTalking() {
        guard !isRecording else { return }
        wantsRecording = true
        if !socket.isConnected {
            socket.connect()
        }
        audio.requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard self.wantsRecording, granted else {
                if !granted { self.micDenied = true }
                return
            }
            self.audio.startRecording()
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
            audio.playAudioChunk(data)
        case .turnDone:
            isWaitingReply = false
            audio.finishPlayback()
        case .error(let message):
            isWaitingReply = false
            messages.append(ChatMessage(role: .error, text: message))
        }
    }
}
