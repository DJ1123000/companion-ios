import AVFoundation
import Foundation

/// Recording (16kHz 16-bit mono PCM via AVAudioEngine tap) and
/// playback (WAV via AVAudioPlayer, PCM streaming via AVAudioPlayerNode,
/// mp3 via AVAudioPlayer).
/// No on-device STT / LLM / TTS: audio only goes to / comes from the server.
///
/// V2 recording fixes (mic-tap crash):
/// - Permission is requested BEFORE touching the engine (caller enforces this
///   via `isMicrophoneAuthorized`); startRecording refuses to run unauthorised.
/// - The input-node tap uses the input node's OWN output format, never a
///   forced 16kHz format. Captured audio is converted to 16kHz PCM16 with
///   AVAudioConverter inside the tap callback.
/// - Taps are never installed or removed while the engine is running: the
///   engine is stopped first in both startRecording and stopRecording.
/// - No force-unwraps anywhere on the audio path; failures print and return.
///
/// V3 playback (WAV passthrough):
/// - The backend now sends the original GLM-4-Voice WAV bytes as binary
///   frames (RIFF header included, 22050Hz mono 16-bit) instead of
///   resampled 16kHz PCM. WAV chunks are buffered and played whole with
///   AVAudioPlayer on finishPlayback(), so the voice is heard exactly as
///   the model produced it (no resampling, no wrong sample rate).
/// - Raw 16kHz PCM16 still streams via AVAudioPlayerNode as a fallback.
/// - finishPlayback() returns true when buffered WAV/mp3 audio started
///   playing; the caller keeps the "speaking" state until
///   onPlaybackFinished fires (AVAudioPlayerDelegate).
final class AudioManager: NSObject {
    static let pcmSampleRate: Double = 16000

    /// Called on a background queue with each captured PCM16 chunk.
    var onAudioChunk: ((Data) -> Void)?

    /// Called on the main queue when a buffered WAV/mp3 finishes playing.
    var onPlaybackFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// 16kHz 16-bit mono PCM — the format the server expects.
    private let targetFormat: AVAudioFormat?
    private var isRecording = false
    private var mp3Buffer = Data()
    private var mp3Mode = false
    private var mp3Player: AVAudioPlayer?
    private var wavBuffer = Data()
    private var wavMode = false
    private var wavPlayer: AVAudioPlayer?
    private let sendQueue = DispatchQueue(label: "companion.audio.send")

    override init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: Self.pcmSampleRate,
                                     channels: 1,
                                     interleaved: true)
        super.init()
        engine.attach(playerNode)
        if let targetFormat {
            engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)
        } else {
            print("audio: could not create 16kHz PCM16 target format")
        }
    }

    /// Configure the audio session for simultaneous record + playback.
    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
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

    /// True only when the user has already granted microphone access.
    var isMicrophoneAuthorized: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    // MARK: - Recording

    /// Starts recording. Returns true on success. The caller must have
    /// already obtained microphone permission; refuses to run otherwise.
    @discardableResult
    func startRecording() -> Bool {
        guard !isRecording else { return true }
        guard let targetFormat else {
            print("audio: target format unavailable, cannot record")
            return false
        }
        guard isMicrophoneAuthorized else {
            print("audio: microphone not authorized, refusing to record")
            return false
        }
        configureSession()
        stopPlayback()
        // Never install a tap while the engine is running.
        if engine.isRunning {
            engine.stop()
        }
        let input = engine.inputNode
        // Use the input node's OWN output format for the tap.
        let inputFormat = input.outputFormat(forBus: 0)
        // Build a converter to 16kHz PCM16 (nil when already in target format).
        let converter: AVAudioConverter?
        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == targetFormat.channelCount,
           inputFormat.commonFormat == targetFormat.commonFormat {
            converter = nil
        } else {
            guard let created = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                print("audio: could not create converter from \(inputFormat) to \(targetFormat)")
                return false
            }
            converter = created
        }
        let target = targetFormat
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleInputBuffer(buffer, converter: converter, targetFormat: target)
        }
        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            print("engine start error: \(error)")
            return false
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        // Never remove a tap while the engine is running.
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Convert one captured buffer to 16kHz PCM16 and emit it.
    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer,
                                   converter: AVAudioConverter?,
                                   targetFormat: AVAudioFormat) {
        if let converter {
            // Down/convert to the 16kHz target format.
            let ratio = Self.pcmSampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                   frameCapacity: capacity) else { return }
            var convertError: NSError?
            var inputBuffer: AVAudioPCMBuffer? = buffer
            let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                if let pending = inputBuffer {
                    inputBuffer = nil
                    outStatus.pointee = .haveData
                    return pending
                }
                outStatus.pointee = .noDataNow
                return nil
            }
            if let convertError {
                print("audio convert error: \(convertError)")
                return
            }
            guard status == .haveData, outBuffer.frameLength > 0,
                  let channelData = outBuffer.int16ChannelData else { return }
            let frames = Int(outBuffer.frameLength)
            let data = Data(bytes: channelData[0], count: frames * 2)
            sendQueue.async { [weak self] in self?.onAudioChunk?(data) }
        } else {
            // Already in 16kHz PCM16 format.
            guard let channelData = buffer.int16ChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let data = Data(bytes: channelData[0], count: frames * 2)
            sendQueue.async { [weak self] in self?.onAudioChunk?(data) }
        }
    }

    // MARK: - Playback

    /// Feed one binary chunk from the server. WAV (RIFF) and mp3 (ID3) are
    /// buffered and played whole at `finishPlayback()`; anything else is
    /// streamed immediately as 16kHz PCM16.
    func playAudioChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        if !wavMode && !mp3Mode && isWAV(data) {
            wavMode = true
            wavBuffer = Data()
        }
        if wavMode {
            wavBuffer.append(data)
            return
        }
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

    /// Call when the server sends {"type":"done"}: flushes a buffered WAV
    /// or mp3. Returns true when buffered audio started playing — the
    /// caller should keep the "speaking" state until onPlaybackFinished
    /// fires. Returns false when nothing was buffered (PCM path).
    @discardableResult
    func finishPlayback() -> Bool {
        if wavMode {
            wavMode = false
            let data = wavBuffer
            wavBuffer = Data()
            guard !data.isEmpty else { return false }
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                wavPlayer = player
                player.prepareToPlay()
                player.play()
                return true
            } catch {
                print("wav playback error: \(error)")
                return false
            }
        }
        guard mp3Mode else { return false }
        mp3Mode = false
        let data = mp3Buffer
        mp3Buffer = Data()
        guard !data.isEmpty else { return false }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            mp3Player = player
            player.prepareToPlay()
            player.play()
            return true
        } catch {
            print("mp3 playback error: \(error)")
            return false
        }
    }

    func stopPlayback() {
        wavMode = false
        wavBuffer = Data()
        wavPlayer?.stop()
        wavPlayer = nil
        mp3Mode = false
        mp3Buffer = Data()
        mp3Player?.stop()
        mp3Player = nil
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    private func playPCM(_ data: Data) {
        guard let targetFormat else {
            print("audio: target format unavailable, cannot play")
            return
        }
        let frames = data.count / 2
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
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

    /// WAV files start with the 4-byte "RIFF" magic.
    private func isWAV(_ data: Data) -> Bool {
        data.count >= 4 && data[0] == 0x52 && data[1] == 0x49
            && data[2] == 0x46 && data[3] == 0x46 // "RIFF"
    }

    /// Only an ID3 tag counts as mp3. (A bare 0xFF frame-sync check would
    /// misfire on raw PCM16 data, which can start with those bytes.)
    private func isMP3(_ data: Data) -> Bool {
        data.count >= 3 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 // "ID3"
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onPlaybackFinished?()
    }
}
