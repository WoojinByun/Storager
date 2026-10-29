import Foundation
import Testing
@testable import StoragerCore

struct VolumeStatsTests {
    @Test func derivedValues() {
        let stats = VolumeStats(total: 1000, available: 300, availableForImportantUsage: 450)
        #expect(stats.purgeable == 150)
        #expect(stats.used == 550)
        #expect(stats.used + stats.purgeable + stats.available == stats.total)
        #expect(abs(stats.usedFraction - 0.55) < 0.0001)
    }

    @Test func importantUsageBelowAvailableMeansNoPurgeable() {
        let stats = VolumeStats(total: 1000, available: 300, availableForImportantUsage: 200)
        #expect(stats.purgeable == 0)
        #expect(stats.used == 700)
    }

    @Test func readsHomeVolume() throws {
        let stats = try VolumeStats.read()
        #expect(stats.total > 0)
        #expect(stats.available > 0)
        #expect(stats.available <= stats.total)
    }

    private struct ReadFailure: Error {}

    @Test func importantUsageFallsBackWhenReadThrows() {
        #expect(VolumeStats.importantUsage(fallback: 300) { throw ReadFailure() } == 300)
    }

    @Test func importantUsageFallsBackWhenValueMissing() {
        #expect(VolumeStats.importantUsage(fallback: 300) { nil } == 300)
    }

    @Test func importantUsageUsesReadValue() {
        #expect(VolumeStats.importantUsage(fallback: 300) { 450 } == 450)
    }
}
