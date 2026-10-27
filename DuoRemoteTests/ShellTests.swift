import Testing
import CoreGraphics
import Foundation
import IOSurface
import UIKit
@testable import DuoRemote

struct ShellTests {
    let bar = CGRect(x: 0, y: 0, width: 874, height: 56)

    @Test func noFoldMeansWholeBar() {
        #expect(FoldSplit.decide(bar: bar, fold: nil) == nil)
    }

    @Test func verticalFoldSplitsBar() {
        let fold = CGRect(x: 455, y: -300, width: 40, height: 700)
        #expect(FoldSplit.decide(bar: bar, fold: fold) == FoldSplit(leading: 455, gap: 40, trailing: 379))
    }

    @Test func horizontalFoldDoesNotSplit() {
        #expect(FoldSplit.decide(bar: bar, fold: CGRect(x: 0, y: 20, width: 874, height: 40)) == nil)
    }

    @Test func foldAboveBarDoesNotSplit() {
        #expect(FoldSplit.decide(bar: bar, fold: CGRect(x: 455, y: -400, width: 40, height: 300)) == nil)
    }

    @Test func zeroWidthFlatFoldDoesNotSplit() {
        #expect(FoldSplit.decide(bar: bar, fold: CGRect(x: 437, y: -300, width: 0, height: 700)) == nil)
    }

    @Test func tinySideKeepsBarWhole() {
        #expect(FoldSplit.decide(bar: bar, fold: CGRect(x: 800, y: 0, width: 40, height: 700)) == nil)
    }

    @Test func clearRegionPicksLargerSide() {
        let c = CGRect(x: 0, y: 0, width: 874, height: 402)
        #expect(foldClearRegion(container: c, fold: nil) == c)
        let v = foldClearRegion(container: c, fold: CGRect(x: 455, y: 0, width: 40, height: 402))
        #expect(v == CGRect(x: 0, y: 0, width: 455, height: 402))
        let h = foldClearRegion(container: CGRect(x: 0, y: 0, width: 400, height: 900),
                                fold: CGRect(x: 0, y: 600, width: 400, height: 40))
        #expect(h == CGRect(x: 0, y: 0, width: 400, height: 600))
    }
}

/// The app's own executable (the tests run inside the app) is signed by the linker, with SHA-256 page hashes.
struct CodeIntegrityTests {
    private func ownExecutable() throws -> Data {
        let url = try #require(Bundle.main.executableURL)
        return try Data(contentsOf: url)
    }

    @Test func intactExecutableHasNoDamagedPages() throws {
        let damaged = try #require(CodeIntegrity.damagedPages(in: ownExecutable()))
        #expect(damaged.isEmpty)
    }

    @Test func flippedByteIsFoundOnItsPage() throws {
        var data = try ownExecutable()
        let offset = data.count / 2        // well inside the signed code, whatever the build's layout
        data[offset] ^= 0xFF
        let damaged = try #require(CodeIntegrity.damagedPages(in: data))
        #expect(damaged.count == 1)
        #expect(damaged.first.map { $0 <= offset && offset < $0 + 0x4000 } == true)
    }

    @Test func notAMachOIsNotChecked() {
        #expect(CodeIntegrity.damagedPages(in: Data()) == nil)
        #expect(CodeIntegrity.damagedPages(in: Data(repeating: 0xAB, count: 4096)) == nil)
    }
}

struct FramePresenterTests {
    private func surface(_ width: Int, _ height: Int, fill: UInt8) throws -> IOSurface {
        let s = try #require(IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                    .bytesPerRow: width * 4, .pixelFormat: UInt32(0x4247_5241)]))  // 'BGRA'
        s.lock(options: [], seed: nil)
        memset(s.baseAddress, Int32(fill), s.allocationSize)
        s.unlock(options: [], seed: nil)
        return s
    }

    private func pixel(_ s: IOSurface, _ x: Int, _ y: Int) -> UInt8 {
        s.lock(options: .readOnly, seed: nil)
        defer { s.unlock(options: .readOnly, seed: nil) }
        return s.baseAddress.load(fromByteOffset: y * s.bytesPerRow + x * 4, as: UInt8.self)
    }

    private func paint(_ s: IOSurface, x: Int, y: Int, width: Int, height: Int, _ value: UInt8) {
        s.lock(options: [], seed: nil)
        defer { s.unlock(options: [], seed: nil) }
        for row in y..<(y + height) { memset(s.baseAddress + row * s.bytesPerRow + x * 4, Int32(value), width * 4) }
    }

    @Test func updatesAppearOnlyWhenPresented() throws {
        let back = try surface(64, 32, fill: 1)
        let presenter = FramePresenter()
        let front = try #require(presenter.attach(back))
        #expect(pixel(front, 10, 10) == 1)                       // starts as a copy

        paint(back, x: 0, y: 0, width: 64, height: 16, 7)         // an update, half decoded,
        presenter.markUpdated(x: 0, y: 0, width: 64, height: 16)
        #expect(pixel(front, 10, 10) == 1)                       // isn't shown yet

        paint(back, x: 0, y: 16, width: 64, height: 16, 7)
        presenter.markUpdated(x: 0, y: 16, width: 64, height: 16)
        #expect(presenter.present())
        #expect(pixel(front, 10, 10) == 7 && pixel(front, 10, 30) == 7)   // all of it at once
        #expect(!presenter.present())                            // nothing new since
    }

    @Test func onlyReportedRegionsAreCopied() throws {
        let back = try surface(64, 32, fill: 1)
        let presenter = FramePresenter()
        let front = try #require(presenter.attach(back))
        paint(back, x: 0, y: 0, width: 64, height: 32, 9)         // changed everywhere, but only
        presenter.markUpdated(x: 8, y: 4, width: 4, height: 4)    // this rectangle was reported
        presenter.present()
        #expect(pixel(front, 9, 5) == 9)
        #expect(pixel(front, 40, 20) == 1)
    }
}

struct OuterPictureTests {
    @Test func cameraRunsOnlyWhileThePictureCanShow() {
        #expect(OuterPicture.cameraShouldRun(enabled: true, hasPicture: true, unfolded: true, active: true))
        #expect(!OuterPicture.cameraShouldRun(enabled: false, hasPicture: true, unfolded: true, active: true))
        #expect(!OuterPicture.cameraShouldRun(enabled: true, hasPicture: false, unfolded: true, active: true))
        #expect(!OuterPicture.cameraShouldRun(enabled: true, hasPicture: true, unfolded: false, active: true))
        #expect(!OuterPicture.cameraShouldRun(enabled: true, hasPicture: true, unfolded: true, active: false))
    }

    @Test func bigPhotosAreShrunkToAJPEG() throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000),
                                            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .pngData { $0.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000)) }
        let jpeg = try #require(OuterPicture.prepare(photo, maxPixels: 1000))
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size == CGSize(width: 1000, height: 750))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(OuterPicture.prepare(Data("not a picture".utf8)) == nil)
    }
}

/// The video stream's wire format is little-endian (windows/DuoPCStreamer/Protocol.cs).
struct StreamWireTests {
    @Test func littleEndianRoundTrips() {
        var data = Data([0xFF])
        data.appendLE(UInt32(0x0102_0304))
        data.appendLE(Int16(-120))
        #expect(data == Data([0xFF, 0x04, 0x03, 0x02, 0x01, 0x88, 0xFF]))
        #expect(data.readLE(UInt32.self, at: 1) == 0x0102_0304)
        #expect(Int16(bitPattern: data.readLE(UInt16.self, at: 5)) == -120)
    }

    @Test func readsFromASliceByItsOwnOffsets() {
        let whole = Data([0, 0, 0x2A, 0, 0, 0])
        let slice = whole[2...]                       // startIndex 2
        #expect(slice.readLE(UInt32.self, at: 0) == 0x2A)
    }

    @Test func statsFromOlderAndNewerPCs() throws {
        var old = Data()
        old.appendLE(UInt16(60)); old.appendLE(UInt16(0)); old.appendLE(UInt32(4_200)); old.appendLE(UInt16(25))
        let a = try #require(VideoStats(payload: old))
        #expect(a == VideoStats(fps: 60, skipped: 0, kbps: 4_200, bestRoundTripMs: 25, roundTripMs: 25, capKbps: nil))
        #expect(!a.isStrained)

        var new = old
        new.appendLE(UInt16(140)); new.appendLE(UInt32(12_000))
        let b = try #require(VideoStats(payload: new))
        #expect(b.roundTripMs == 140 && b.capKbps == 12_000)
        #expect(b.isStrained)                          // 115 ms queued on top of the best round trip
        #expect(VideoStats(payload: Data([1, 2, 3])) == nil)
    }

    @Test func adtsHeaderGivesTheDecoderItsConfig() throws {
        // AAC-LC, 48 kHz, stereo, 10-byte frame (7-byte header, no CRC) with a 3-byte payload.
        let frame = Data([0xFF, 0xF1, 0x4C, 0x80, 0x01, 0x5F, 0xFC, 0xAA, 0xBB, 0xCC])
        let adts = try #require(ADTSFrame(frame))
        #expect(adts.objectType == 2 && adts.sampleRate == 48_000 && adts.channels == 2)
        #expect(adts.payload == Data([0xAA, 0xBB, 0xCC]))
        #expect(adts.audioSpecificConfig == Data([0x11, 0x90]))
        #expect(ADTSFrame(frame.prefix(8)) == nil)     // shorter than its header says
        #expect(ADTSFrame(Data([0x00] + frame.dropFirst())) == nil)
    }
}

