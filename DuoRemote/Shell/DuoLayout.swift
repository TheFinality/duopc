import SwiftUI

/// Fold helpers. Everything reads the space a view is GIVEN (its GeometryProxy) and the iOS 27.1
/// reserved regions. No device model, screen size, idiom or hinge angle is consulted.
nonisolated enum DuoFold {
    /// The first division (fold) in the proxy's own coordinates, or nil when there is none.
    /// Inactive (flat) folds are zero-width; callers treat those as "no fold".
    static func division(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division).first?.frame
    }

    /// The fold including an inactive one: when the device is flat it is still reported, with
    /// zero thickness, at the same place.
    static func divisionIncludingInactive(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division, options: .includeInactive).first?.frame
    }
}

/// How a bar is divided around a vertical fold: widths of the leading part, the fold gap and the
/// trailing part. All in the bar's own coordinates.
nonisolated struct FoldSplit: Equatable, Sendable {
    var leading: CGFloat
    var gap: CGFloat
    var trailing: CGFloat

    /// Pure decision: does `fold` cross `bar` (both in one coordinate space) vertically, and if so
    /// where to split. nil when there is no fold, it's horizontal, it misses the bar, or either side
    /// would be narrower than `minSide` (then the bar stays whole).
    static func decide(bar: CGRect, fold: CGRect?, minSide: CGFloat = 120) -> FoldSplit? {
        guard let fold, fold.width >= 1, fold.height > fold.width else { return nil }
        guard fold.minY < bar.maxY, fold.maxY > bar.minY else { return nil }
        guard fold.minX < bar.maxX, fold.maxX > bar.minX else { return nil }
        let leading = fold.minX - bar.minX
        let trailing = bar.maxX - fold.maxX
        guard leading >= minSide, trailing >= minSide else { return nil }
        return FoldSplit(leading: leading, gap: fold.width, trailing: trailing)
    }
}

/// Where floating overlays may sit: the larger side of the fold (never on it). `container` and
/// `fold` share one coordinate space. Returns `container` when there is no fold.
nonisolated func foldClearRegion(container: CGRect, fold: CGRect?) -> CGRect {
    guard let fold, fold.width >= 1, fold.height >= 1, fold.intersects(container) else { return container }
    if fold.height > fold.width {
        let left = CGRect(x: container.minX, y: container.minY, width: max(0, fold.minX - container.minX), height: container.height)
        let right = CGRect(x: fold.maxX, y: container.minY, width: max(0, container.maxX - fold.maxX), height: container.height)
        return left.width >= right.width ? left : right
    }
    let top = CGRect(x: container.minX, y: container.minY, width: container.width, height: max(0, fold.minY - container.minY))
    let bottom = CGRect(x: container.minX, y: fold.maxY, width: container.width, height: max(0, container.maxY - fold.maxY))
    return top.height >= bottom.height ? top : bottom
}

/// Two views either side of a fold gap. Keys never run across the gap.
struct FoldSplitRow<Left: View, Right: View>: View {
    let split: FoldSplit
    let left: Left
    let right: Right

    init(split: FoldSplit, @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.split = split
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: split.leading)
            Color.clear.frame(width: split.gap, height: 1)
            right.frame(width: split.trailing)
        }
    }
}
