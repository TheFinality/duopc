@preconcurrency import RoyalVNCKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Network
import VideoToolbox
import os

/// What a session needs from its connection for input, whether that's VNC or the video stream.
nonisolated protocol RemoteLink: AnyObject {
    func mouseMove(x: UInt16, y: UInt16)
    func mouseButtonDown(_ button: VNCMouseButton, x: UInt16, y: UInt16)
    func mouseButtonUp(_ button: VNCMouseButton, x: UInt16, y: UInt16)
    func mouseWheel(_ wheel: VNCMouseWheel, x: UInt16, y: UInt16, steps: UInt32)
    func keyDown(_ key: VNCKeyCode)
    func keyUp(_ key: VNCKeyCode)
}

extension VNCConnection: RemoteLink {}

extension RemoteLink {
    func tap(_ key: VNCKeyCode) {
        keyDown(key)
        keyUp(key)
    }
}

/// DuoPC's video channel through DuoPC Gateway: the PC's screen as HEVC from its GPU encoder, decoded
/// by the phone's hardware; pointer and keys go back the same way. The wire format is in
/// windows/DuoPCStreamer/Protocol.cs. Everything runs on the stream's own queue; events come out
/// through `onEvent`.
nonisolated final class VideoStream: RemoteLink, @unchecked Sendable {
    enum Failure: Sendable, Equatable {
        case rejected, certificateMismatch, unavailable, closed
        case network(String)
    }

    enum Event: @unchecked Sendable {
        /// A decoded frame, in the BGRA IOSurface the canvas draws.
        case frame(SurfaceBox)
        /// A notice from the PC (e.g. the screen can't be captured right now).
        case notice(String)
        /// Once a second from the PC: frames sent, frames skipped to keep the delay down, kbps, best round trip.
        case stats(fps: Int, skipped: Int, kbps: Int, roundTripMs: Int)
        /// Something worth a line in the connection log (decoder trouble and recovery).
        case log(String)
        case closed(Failure?)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "duopc.video", qos: .userInteractive)
    private let connection: NWConnection
    private let token: Data
    private let pinMismatch = OSAllocatedUnfairLock(initialState: false)
    private var bitrateKbps: Int
    private let fps: Int
    // Queue-confined.
    private var decoder: HEVCDecoder?
    /// The last Config, to rebuild the decoder from.
    private var config: (width: Int, height: Int, hvcC: Data)?
    private var failedFrames = 0
    private var finished = false
    private var closing = false

    init(host: String, port: UInt16, gateway: VNCGatewaySettings, bitrateKbps: Int, fps: Int) {
        token = gateway.token
        self.bitrateKbps = bitrateKbps
        self.fps = fps
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let mismatch = pinMismatch
        let tls = VNCGatewaySettings.tlsOptions(pinning: gateway.certificateSHA256,
                                                onMismatch: { mismatch.withLock { $0 = true } })
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.expiredDNSBehavior = .allow
        connection = NWConnection(host: .init(host), port: NWEndpoint.Port(rawValue: port) ?? 5960, using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
    }

    func close() {
        queue.async { [self] in
            closing = true
            connection.cancel()
        }
    }

    // MARK: Input (RemoteLink)

    func mouseMove(x: UInt16, y: UInt16) {
        var payload = Data()
        payload.appendLE(Int32(x)); payload.appendLE(Int32(y))
        send(0x11, payload)
    }

    func mouseButtonDown(_ button: VNCMouseButton, x: UInt16, y: UInt16) {
        mouseMove(x: x, y: y)
        send(0x12, Data([Self.code(button), 1]))
    }

    func mouseButtonUp(_ button: VNCMouseButton, x: UInt16, y: UInt16) {
        mouseMove(x: x, y: y)
        send(0x12, Data([Self.code(button), 0]))
    }

    func mouseWheel(_ wheel: VNCMouseWheel, x: UInt16, y: UInt16, steps: UInt32) {
        let notches = Int16(clamping: Int(steps) * 120)
        let (dx, dy): (Int16, Int16) = switch wheel {
        case .up: (0, notches)
        case .down: (0, -notches)
        case .left: (-notches, 0)
        case .right: (notches, 0)
        }
        var payload = Data()
        payload.appendLE(dx); payload.appendLE(dy)
        send(0x13, payload)
    }

    func keyDown(_ key: VNCKeyCode) { sendKey(key, down: true) }
    func keyUp(_ key: VNCKeyCode) { sendKey(key, down: false) }

    /// Asks the PC for a fresh keyframe (it restarts its encoder), e.g. to repair a stuck picture.
    func requestKeyframe() {
        send(0x18, Data())
    }

    /// Asks the PC to restart its encoder at this bitrate.
    func setBitrate(kbps: Int) {
        queue.async { [self] in bitrateKbps = kbps }
        var payload = Data()
        payload.appendLE(UInt32(kbps))
        send(0x16, payload)
    }

    private func sendKey(_ key: VNCKeyCode, down: Bool) {
        var payload = Data()
        payload.appendLE(key.rawValue)
        payload.append(down ? 1 : 0)
        send(0x14, payload)
    }

    private static func code(_ button: VNCMouseButton) -> UInt8 {
        switch button { case .left: 1; case .middle: 2; case .right: 3 }
    }

    private func send(_ type: UInt8, _ payload: Data) {
        var message = Data([type])
        message.appendLE(UInt32(payload.count))
        message.append(payload)
        connection.send(content: message, completion: .idempotent)
    }

    // MARK: Connection

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // "DPC2" + token + channel 2 (video); then the gateway answers with one byte.
            var hello = Data("DPC2".utf8)
            hello.append(token)
            hello.append(2)
            connection.send(content: hello, completion: .idempotent)
            receive(1) { [self] reply in
                switch reply.first {
                case 0x00:
                    var start = Data()
                    start.appendLE(UInt32(bitrateKbps)); start.appendLE(UInt16(fps))
                    send(0x10, start)
                    readMessage()
                case 0x01: finish(.rejected)
                default: finish(.unavailable)
                }
            }
        case .waiting(let error), .failed(let error):
            finish(pinMismatch.withLock { $0 } ? .certificateMismatch : .network(error.localizedDescription))
        case .cancelled:
            finish(closing ? nil : .closed)
        default:
            break
        }
    }

    private func readMessage() {
        receive(5) { [self] header in
            let type = header[header.startIndex]
            let length = Int(header.readLE(UInt32.self, at: 1))
            guard length <= 64 * 1024 * 1024 else { return finish(.network("The PC sent an oversized message.")) }
            guard length > 0 else { handle(type, Data()); return readMessage() }
            receive(length) { [self] payload in
                handle(type, payload)
                readMessage()
            }
        }
    }

    private func handle(_ type: UInt8, _ payload: Data) {
        switch type {
        case 0x01 where payload.count > 11:   // Config: u32 width, u32 height, u16 fps, u8 codec, hvcC
            let width = Int(payload.readLE(UInt32.self, at: 0)), height = Int(payload.readLE(UInt32.self, at: 4))
            config = (width, height, payload.subdata(in: (payload.startIndex + 11)..<payload.endIndex))
            failedFrames = 0
            decoder = HEVCDecoder(width: width, height: height, hvcC: config!.hvcC)
            if decoder == nil { onEvent?(.notice("This iPhone couldn't set up a decoder for the PC's video.")) }
        case 0x02 where payload.count > 9:    // Frame: u8 flags, u64 time, sample
            let result = decoder?.decode(payload.subdata(in: (payload.startIndex + 9)..<payload.endIndex))
            // Acknowledge every frame, decoded or not: the PC paces itself by these (see Pacer.cs).
            send(0x17, payload.subdata(in: (payload.startIndex + 1)..<(payload.startIndex + 9)))
            guard let pixels = result?.pixels, let ref = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else {
                decodeFailed(status: result?.status ?? 0)
                return
            }
            if failedFrames > 0 {
                onEvent?(.log("decoding recovered after \(failedFrames) failed frames"))
                failedFrames = 0
            }
            let surface = unsafeBitCast(ref, to: IOSurface.self)
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            onEvent?(.frame(SurfaceBox(surface: surface, size: size, owner: pixels)))
        case 0x03 where !payload.isEmpty:     // Status: u8 code, text
            onEvent?(.notice(String(decoding: payload.dropFirst(), as: UTF8.self)))
        case 0x05 where payload.count >= 10:  // Stats: u16 fps, u16 skipped, u32 kbps, u16 round trip ms
            onEvent?(.stats(fps: Int(payload.readLE(UInt16.self, at: 0)), skipped: Int(payload.readLE(UInt16.self, at: 2)),
                            kbps: Int(payload.readLE(UInt32.self, at: 4)), roundTripMs: Int(payload.readLE(UInt16.self, at: 8))))
        default:
            break
        }
    }

    /// A frame didn't decode. A few in a row is normal right after skipped frames (the rolling
    /// refresh repairs it); a run of them, or a dead decoder session (iOS can reset the hardware
    /// decoder), means rebuilding the decoder and asking for a keyframe.
    private func decodeFailed(status: OSStatus) {
        failedFrames += 1
        let sessionDead = status == kVTInvalidSessionErr
        if failedFrames == 1 || sessionDead { onEvent?(.log("decode failed (\(status))")) }
        guard sessionDead || failedFrames % 45 == 0, let config else { return }
        onEvent?(.log("rebuilding the decoder after \(failedFrames) failed frames; asking for a keyframe"))
        decoder = HEVCDecoder(width: config.width, height: config.height, hvcC: config.hvcC)
        requestKeyframe()
    }

    private func receive(_ count: Int, then: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.count == count { return then(data) }
            if let error { return finish(.network(error.localizedDescription)) }
            if isComplete { return finish(.closed) }
            finish(.network("The connection to the PC was cut short."))
        }
    }

    private func finish(_ failure: Failure?) {
        guard !finished else { return }
        finished = true
        decoder = nil
        connection.cancel()
        onEvent?(.closed(closing ? nil : failure))
    }
}

/// HEVC → BGRA IOSurface frames with VideoToolbox (hardware), one sample at a time.
nonisolated final class HEVCDecoder {
    private let format: CMVideoFormatDescription
    private let session: VTDecompressionSession

    init?(width: Int, height: Int, hvcC: Data) {
        var format: CMVideoFormatDescription?
        let atoms: [CFString: Any] = ["hvcC" as CFString: hvcC as CFData]
        let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
                                             width: Int32(width), height: Int32(height),
                                             extensions: extensions as CFDictionary, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        // BGRA in IOSurfaces: exactly what FramebufferRenderer draws for VNC, so zoom and effects just work.
        let output: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: output as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr,
              let session else { return nil }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.format = format
        self.session = session
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    /// One sample (4-byte length-prefixed NAL units) → its decoded frame, synchronously, and the
    /// decoder's status (for the log when there's no frame).
    func decode(_ sample: Data) -> (pixels: CVPixelBuffer?, status: OSStatus) {
        let length = sample.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return (nil, -1) }
        let copied = sample.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return (nil, copied) }
        var sampleBuffer: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return (nil, -2) }
        nonisolated(unsafe) var decoded: CVPixelBuffer?
        nonisolated(unsafe) var outputStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            outputStatus = status
            if status == noErr { decoded = image }
        }
        return status == noErr ? (decoded, outputStatus) : (nil, status)
    }
}

nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value = T.zero
        Swift.withUnsafeMutableBytes(of: &value) { target in
            let start = startIndex + offset
            target.copyBytes(from: self[start..<(start + MemoryLayout<T>.size)])
        }
        return T(littleEndian: value)
    }
}
