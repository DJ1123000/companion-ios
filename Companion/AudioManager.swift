import AVFoundation
import Foundation

/// Recording (16kHz 16-bit mono PCM via AVAudioEngine tap) and
/// playback (PCM streaming via AVAudioPlayerNode, mp3 via AVAudioPlayer).
/// No on-device STT / LLM / TTS: audio only goes to / comes from the server.
final class AudioManager: NSObject {
    static let pcmSampleRate: Double = 16000

    /// Called on a background queue with each captured PCM16 chunk.
    var onAudioChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pcmFormat: AVAudioFormat
    private var isRecording = false
    private var mp3Buffer = Data()
    private var mp3Mode = false
    private var mp3Player: AVAudioPlayer?
    private let sendQueue = DispatchQueue(label: "companion.audio.send")

    override init() {
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: Self.pcmSampleRate,
                                  channels: 1,
                                  interleaved: true)!
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: pcmFormat)
    }

    /// Configure the audio session for simultaneous record + playback.
    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("audio session error: \(error)")
        }
    }

    /// Ask for microphone permission; calls back on the main queue.
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        configureSession()
        stopPlayback()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: pcmFormat) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.int16ChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let data = Data(bytes: channelData[0], count: frames * 2)
            self.sendQueue.async { self.onAudioChunk?(data) }
        }
        do {
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            print("engine start error: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        if !playerNode.isPlaying {
            engine.stop()
        }
    }

    // MARK: - Playback

    /// Feed one binary chunk from the server. PCM16 chunks are streamed
    /// immediately; mp3 (ID3 or frame sync) is buffered and played at `finishPlayback()`.
    func playAudioChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        if !mp3Mode && isMP3(data) {
            mp3Mode = true
            mp3Buffer = Data()
        }
        if mp3Mode {
            mp3Buffer.append(data)
            return
        }
        playPCM(data)
    }

    /// Call when the server sends {"type":"done"}: flushes a buffered mp3.
    func finishPlayback() {
        guard mp3Mode else { return }
        mp3Mode = false
        let data = mp3Buffer
        mp3Buffer = Data()
        guard !data.isEmpty else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            mp3Player = player
            player.prepareToPlay()
            player.play()
        } catch {
            print("mp3 playback error: \(error)")
        }
    }

    func stopPlayback() {
        mp3Mode = false
        mp3Buffer = Data()
        mp3Player?.stop()
        mp3Player = nil
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    private func playPCM(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.int16ChannelData?[0] else { return }
            dst.update(from: src, count: frames)
        }
        if !engine.isRunning {
            do {
                engine.prepare()
                try engine.start()
            } catch {
                print("engine start error: \(error)")
                return
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer)
    }

    private func isMP3(_ data: Data) -> Bool {
        if data.count >= 3,
           data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 { // "ID3"
            return true
        }
        if data.count >= 2, data[0] == 0xFF, (data[1] & 0xE0) == 0xE0 { // frame sync
            return true
        }
        return false
    }
}
