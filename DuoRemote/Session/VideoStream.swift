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
            decoder = HEVCDecoder(width: width, height: height, hvcC: payload.subdata(in: (payload.startIndex + 11)..<payload.endIndex))
            if decoder == nil { onEvent?(.notice("This iPhone couldn't set up a decoder for the PC's video.")) }
        case 0x02 where payload.count > 9:    // Frame: u8 flags, u64 time, sample
            guard let decoder,
                  let pixels = decoder.decode(payload.subdata(in: (payload.startIndex + 9)..<payload.endIndex)),
                  let ref = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
            let surface = unsafeBitCast(ref, to: IOSurface.self)
            let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            onEvent?(.frame(SurfaceBox(surface: surface, size: size, owner: pixels)))
        case 0x03 where !payload.isEmpty:     // Status: u8 code, text
            onEvent?(.notice(String(decoding: payload.dropFirst(), as: UTF8.self)))
        default:
            break
        }
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

    /// One sample (4-byte length-prefixed NAL units) → its decoded frame, synchronously.
    func decode(_ sample: Data) -> CVPixelBuffer? {
        let length = sample.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = sample.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        nonisolated(unsafe) var decoded: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { decoded = image }
        }
        return status == noErr ? decoded : nil
    }
}

nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { target in
            let start = startIndex + offset
            target.copyBytes(from: self[start..<(start + MemoryLayout<T>.size)])
        }
        return T(littleEndian: value)
    }
}
