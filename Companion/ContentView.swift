import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statusBar

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if viewModel.messages.isEmpty {
                                Text("按住下方按钮说话，或输入文字开始聊天")
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 40)
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
                        .padding(.vertical, 12)
                    }
                    .onChange(of: viewModel.messages.count) { _ in
                        if let last = viewModel.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                textInputRow

                holdToTalkButton
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

    private func messageRow(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor(for: message.role))
                .foregroundColor(message.role == .user ? .white : .primary)
                .cornerRadius(16)
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

    private var holdToTalkButton: some View {
        let recording = viewModel.isRecording
        return ZStack {
            Circle()
                .fill(recording ? Color.red.opacity(0.15) : Color.blue.opacity(0.1))
                .frame(width: 96, height: 96)
            Circle()
                .fill(recording ? Color.red : Color.blue)
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                )
                .scaleEffect(recording ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: recording)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in viewModel.startTalking() }
                .onEnded { _ in viewModel.stopTalking() }
        )
        .overlay(
            Text(recording ? "松开发送" : "按住说话")
                .font(.footnote)
                .foregroundColor(.secondary)
                .offset(y: 58)
        )
        .accessibilityLabel(recording ? "正在录音，松开发送" : "按住说话")
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
