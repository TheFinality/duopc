import Testing
import CoreGraphics
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
