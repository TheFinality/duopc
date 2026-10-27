import AVFoundation
import os

/// Plays the PC's sound: AAC-LC in ADTS frames from the video channel (see Protocol.cs). Keeps about
/// 60 ms queued, enough to ride out network jitter without a noticeable delay; if it falls further
/// behind than that (the network stalled, then delivered a burst), it drops frames to catch up.
/// Used on the video stream's queue only.
nonisolated final class PCSoundPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let output: AVAudioFormat
    private var input: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputKey: (rate: Int, channels: Int)?
    /// Frames scheduled and not yet played. Completion callbacks come on the engine's thread.
    private let queued = OSAllocatedUnfairLock(initialState: 0)

    static let cushion = 0.06
    static let maxBehind = 0.25

    init?() {
        guard let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return nil }
        self.output = output
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? audioSession.setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        guard (try? engine.start()) != nil else { return nil }
        player.play()
    }

    deinit {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func play(adts frame: Data) {
        guard let parsed = ADTSFrame(frame), let pcm = decode(parsed) else { return }
        let rate = output.sampleRate
        if !engine.isRunning {
            // A phone call or a route change stopped the engine: start over with an empty queue.
            player.stop()
            queued.withLock { $0 = 0 }
            guard (try? engine.start()) != nil else { return }
            player.play()
        }
        let behind = queued.withLock { $0 }
        if Double(behind) > rate * Self.maxBehind { return }
        if behind == 0, let silence = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(rate * Self.cushion)) {
            // Starting (or after running dry): a little silence first, so the next frame has time to arrive.
            silence.frameLength = silence.frameCapacity
            schedule(silence)
        }
        schedule(pcm)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        queued.withLock { $0 += frames }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [queued] _ in
            queued.withLock { $0 = max(0, $0 - frames) }
        }
    }

    private func decode(_ frame: ADTSFrame) -> AVAudioPCMBuffer? {
        if inputKey?.rate != frame.sampleRate || inputKey?.channels != frame.channels {
            var description = AudioStreamBasicDescription(
                mSampleRate: Float64(frame.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 2 /* kMPEG4Object_AAC_LC */, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: UInt32(frame.channels), mBitsPerChannel: 0, mReserved: 0)
            guard let format = AVAudioFormat(streamDescription: &description),
                  let converter = AVAudioConverter(from: format, to: output) else { return nil }
            converter.magicCookie = frame.audioSpecificConfig
            input = format
            self.converter = converter
            inputKey = (frame.sampleRate, frame.channels)
        }
        guard let input, let converter else { return nil }
        let size = frame.payload.count
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: size)
        frame.payload.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: size) }
        packet.byteLength = UInt32(size)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(size))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 2048) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return packet
        }
        return status != .error && pcm.frameLength > 0 ? pcm : nil
    }
}

/// One ADTS frame: its header's format fields, and the raw AAC payload after the header.
nonisolated struct ADTSFrame: Equatable {
    let objectType: Int
    let frequencyIndex: Int
    let channels: Int
    let payload: Data

    static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    var sampleRate: Int { Self.sampleRates[frequencyIndex] }

    /// The AudioSpecificConfig (the decoder's magic cookie) these fields describe.
    var audioSpecificConfig: Data {
        Data([UInt8((objectType << 3) | (frequencyIndex >> 1)), UInt8(((frequencyIndex & 1) << 7) | (channels << 3))])
    }

    init?(_ data: Data) {
        let b = [UInt8](data.prefix(7))
        guard b.count == 7, b[0] == 0xFF, b[1] & 0xF0 == 0xF0 else { return nil }
        let headerLength = b[1] & 0x01 == 1 ? 7 : 9   // protection_absent, else a 2-byte CRC follows
        let length = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5]) >> 5)
        objectType = Int(b[2] >> 6) + 1
        frequencyIndex = Int((b[2] >> 2) & 0x0F)
        channels = (Int(b[2] & 0x01) << 2) | Int(b[3] >> 6)
        guard frequencyIndex < Self.sampleRates.count, channels > 0, length > headerLength, length <= data.count else { return nil }
        payload = data.subdata(in: (data.startIndex + headerLength)..<(data.startIndex + length))
    }
}
