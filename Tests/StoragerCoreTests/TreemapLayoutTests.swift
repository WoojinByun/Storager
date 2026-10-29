import CoreGraphics
import Testing
@testable import StoragerCore

struct TreemapLayoutTests {
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
    let tolerance: CGFloat = 0.001

    func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    @Test func preservesAreaRatios() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(weights, in: bounds)
        let total = weights.reduce(0, +)

        for (weight, rect) in zip(weights, rects) {
            let expected = area(bounds) * weight / total
            #expect(abs(area(rect) - expected) < 0.01, "weight \(weight)")
        }
    }

    @Test func staysInsideBoundsWithoutOverlap() {
        let weights: [Double] = [50, 1, 30, 7, 7, 3, 2, 0.5]
        let rects = TreemapLayout.squarify(weights, in: bounds)
        let grown = bounds.insetBy(dx: -tolerance, dy: -tolerance)

        for rect in rects {
            #expect(grown.contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
        let covered = rects.map(area).reduce(0, +)
        #expect(abs(covered - area(bounds)) < 0.01)
    }

    @Test func keepsInputOrderAndZeroesNonPositiveWeights() {
        let rects = TreemapLayout.squarify([1, 0, 3, -2], in: bounds)
        #expect(rects.count == 4)
        #expect(rects[1] == .zero)
        #expect(rects[3] == .zero)
        #expect(area(rects[2]) > area(rects[0]))
    }

    @Test func emptyInputOrEmptyRectGivesZeroRects() {
        #expect(TreemapLayout.squarify([], in: bounds).isEmpty)
        #expect(TreemapLayout.squarify([1, 2], in: .zero) == [.zero, .zero])
    }

    @Test func squarifiedRectsAreNotSlivers() {
        let rects = TreemapLayout.squarify(Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            #expect(ratio < 2.5)
        }
    }
}
