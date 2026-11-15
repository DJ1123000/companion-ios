import SwiftUI

/// What the avatar is doing right now, derived from the view model.
/// File scope so both ContentView and AvatarHeroView can use it.
enum AvatarState: Equatable {
    case idle, listening, speaking, thinking, disconnected
}

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()

    private var avatarState: AvatarState {
        if viewModel.isRecording { return .listening }
        if viewModel.isSpeaking { return .speaking }
        if viewModel.isWaitingReply { return .thinking }
        if viewModel.isConnected { return .idle }
        return .disconnected
    }

    private var avatarStatusText: String {
        switch avatarState {
        case .idle: return "已连接，随时可以聊天"
        case .listening: return "正在听…"
        case .speaking: return "正在说…"
        case .thinking: return "思考中…"
        case .disconnected: return viewModel.statusText
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statusBar

                AvatarHeroView(state: avatarState, statusText: avatarStatusText)
                    .padding(.top, 10)

                messageArea

                Divider()

                textInputRow

                modeSwitcher

                voiceOrbSection
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
            .navigationTitle("AI 陪伴")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { viewModel.onAppear() }
        .alert("无法使用麦克风", isPresented: $viewModel.micDenied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请在“设置 → AI 陪伴 → 麦克风”中允许访问麦克风。")
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
            if !viewModel.isConnected {
                Button("重新连接") { viewModel.onAppear() }
                    .font(.footnote)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground))
    }

    private var statusColor: Color {
        switch viewModel.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    /// Compact message area below the avatar; the avatar stays the hero.
    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if viewModel.messages.isEmpty {
                        Text("点一下下面那个球说话，或输入文字开始聊天")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                            .padding(.horizontal, 32)
                    }
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if viewModel.isWaitingReply {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("对方正在思考…")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor(for: message.role))
                .foregroundColor(message.role == .user ? .white : .primary)
                .cornerRadius(14)
            if message.role != .user { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
    }

    private func bubbleColor(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: return .blue
        case .assistant: return Color(.systemGray5)
        case .error: return Color(.systemRed).opacity(0.15)
        }
    }

    private var textInputRow: some View {
        HStack(spacing: 8) {
            TextField("输入文字…", text: $viewModel.inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .submitLabel(.send)
                .onSubmit { viewModel.sendText() }
            Button("发送") { viewModel.sendText() }
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    /// Two input modes: real-time conversation (tap to start/stop) or
    /// hold-to-talk (press and hold). The choice is persisted.
    private var modeSwitcher: some View {
        Picker("输入方式", selection: $viewModel.inputMode) {
            Text(InputMode.realtime.label).tag(InputMode.realtime)
            Text(InputMode.holdToTalk.label).tag(InputMode.holdToTalk)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 10)
    }

    /// The voice input area: a large dynamic 3D orb (no microphone icon)
    /// plus a hint label. The gesture depends on the selected mode.
    private var voiceOrbSection: some View {
        VStack(spacing: 8) {
            voiceOrb
            Text(orbHintText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var orbHintText: String {
        if viewModel.isRecording {
            return viewModel.inputMode == .realtime ? "正在听，点一下结束" : "松开发送"
        }
        if viewModel.isSpeaking {
            return "小月正在说…"
        }
        return viewModel.inputMode == .realtime ? "点一下开始说话" : "按住说话"
    }

    private var voiceOrb: some View {
        Group {
            if viewModel.inputMode == .realtime {
                VoiceOrbView(state: avatarState)
                    .onTapGesture { viewModel.toggleTalking() }
            } else {
                VoiceOrbView(state: avatarState)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in viewModel.startTalking() }
                            .onEnded { _ in viewModel.stopTalking() }
                    )
            }
        }
        .accessibilityLabel(orbHintText)
    }
}

// MARK: - Voice orb

/// A large dynamic 3D voice button — a glossy gradient sphere, no
/// microphone icon. State-driven motion:
/// - Idle: gentle breathing (slow scale + vertical oscillation).
/// - Listening: an expanding pulsing ring + the orb scales up and glows.
/// - Speaking: the orb sits slightly enlarged + a waveform bar animates.
/// - Thinking: three animated dots under it.
struct VoiceOrbView: View {
    let state: AvatarState

    @State private var breathePhase = false
    @State private var ringPhase = false

    private let orbSize: CGFloat = 128

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Pulsing ring while listening.
                if state == .listening {
                    Circle()
                        .stroke(Color.pink.opacity(0.55), lineWidth: 4)
                        .frame(width: orbSize + 22, height: orbSize + 22)
                        .scaleEffect(ringPhase ? 1.35 : 1.0)
                        .opacity(ringPhase ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: ringPhase)
                        .onAppear { ringPhase = true }
                }

                // Soft outer glow for 3D depth.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.pink.opacity(state == .listening ? 0.5 : 0.3),
                                Color.pink.opacity(0.0)
                            ]),
                            center: .center,
                            startRadius: 24,
                            endRadius: 92
                        )
                    )
                    .frame(width: orbSize + 56, height: orbSize + 56)

                // The orb itself: a warm radial-gradient sphere.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white,
                                Color(red: 1.0, green: 0.88, blue: 0.78),
                                Color(red: 1.0, green: 0.68, blue: 0.62),
                                Color(red: 0.96, green: 0.55, blue: 0.55)
                            ]),
                            center: UnitPoint(x: 0.35, y: 0.3),
                            startRadius: 8,
                            endRadius: 70
                        )
                    )
                    .frame(width: orbSize, height: orbSize)
                    .shadow(color: .pink.opacity(0.45), radius: 20, x: 0, y: 12)

                // Glossy highlight (top-left) for a 3D sheen.
                Ellipse()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 52, height: 30)
                    .blur(radius: 6)
                    .offset(x: -22, y: -30)
            }
            // State-driven scale (listening bigger, speaking slightly up).
            .scaleEffect(stateScale)
            .animation(.easeInOut(duration: 0.3), value: state)
            // Gentle continuous breathing, all states.
            .scaleEffect(breathePhase ? 1.02 : 0.99)
            .offset(y: breathePhase ? -3 : 3)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathePhase)
            .onAppear { breathePhase = true }
            .onChange(of: state) { newState in
                if newState != .listening {
                    ringPhase = false
                }
            }

            // Speaking waveform / thinking dots (fixed height, stable layout).
            ZStack {
                if state == .speaking {
                    WaveformView()
                } else if state == .thinking {
                    ThinkingDotsView()
                }
            }
            .frame(height: 26)
        }
    }

    private var stateScale: CGFloat {
        switch state {
        case .listening: return 1.10
        case .speaking: return 1.05
        default: return 1.0
        }
    }
}

// MARK: - Avatar hero

/// The virtual avatar: large, circular, with state-driven motion.
/// - Idle: gentle continuous bobbing (slow scale + vertical oscillation).
/// - Listening: an expanding pulsing ring + avatar scaled up slightly.
/// - Speaking: a small audio waveform bar under the avatar.
/// - Thinking: three animated dots under the avatar.
struct AvatarHeroView: View {
    let state: AvatarState
    let statusText: String

    @State private var bobPhase = false
    @State private var pulsePhase = false

    init(state: AvatarState, statusText: String) {
        self.state = state
        self.statusText = statusText
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Pulsing ring while listening.
                if state == .listening {
                    Circle()
                        .stroke(Color.red.opacity(0.55), lineWidth: 3)
                        .frame(width: 212, height: 212)
                        .scaleEffect(pulsePhase ? 1.28 : 1.0)
                        .opacity(pulsePhase ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsePhase)
                        .onAppear { pulsePhase = true }
                }
                // Avatar image, gently bobbing while idle.
                Image("XiaoYue")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.pink.opacity(0.35), lineWidth: 3))
                    .shadow(color: .pink.opacity(0.20), radius: 14, x: 0, y: 8)
                    .scaleEffect(state == .idle ? (bobPhase ? 1.02 : 0.98) : 1.0)
                    .offset(y: state == .idle ? (bobPhase ? -5 : 5) : 0)
                    .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: bobPhase)
                    .onAppear { bobPhase = true }
            }
            .scaleEffect(state == .listening ? 1.06 : (state == .speaking ? 1.03 : 1.0))
            .animation(.easeInOut(duration: 0.3), value: state)
            .onChange(of: state) { newState in
                // Reset the pulse so it restarts cleanly next time we listen.
                if newState != .listening {
                    pulsePhase = false
                }
            }

            Text("小月")
                .font(.title2)
                .fontWeight(.bold)

            Text(statusText)
                .font(.footnote)
                .foregroundColor(.secondary)

            // Speaking waveform / thinking dots (fixed height so layout is stable).
            ZStack {
                if state == .speaking {
                    WaveformView()
                } else if state == .thinking {
                    ThinkingDotsView()
                }
            }
            .frame(height: 26)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 1.0, green: 0.97, blue: 0.96))
        )
        .padding(.horizontal, 16)
    }
}

/// A row of vertical bars animating while the avatar speaks.
private struct WaveformView: View {
    private let heights: [CGFloat] = [10, 18, 26, 18, 10]
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.pink.opacity(0.75))
                    .frame(width: 4, height: phase ? heights[i] : heights[i] * 0.4)
                    .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.09), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

/// Three dots animating while the avatar is thinking.
private struct ThinkingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase ? 1.0 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.18), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
