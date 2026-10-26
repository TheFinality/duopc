import Testing
import CoreGraphics
import Foundation
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

