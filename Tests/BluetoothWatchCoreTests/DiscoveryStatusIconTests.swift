import Testing
@testable import BluetoothWatchCore

struct DiscoveryStatusIconTests {
    @Test func distinguishesPausedAttentionUnconfirmedAndWatching() {
        #expect(DiscoveryStatusIconState.current(
            isPaused: true, isScanning: false, classicCoverageConfirmed: false
        ) == .paused)
        #expect(DiscoveryStatusIconState.current(
            isPaused: false, isScanning: false, classicCoverageConfirmed: false
        ) == .attention)
        #expect(DiscoveryStatusIconState.current(
            isPaused: false, isScanning: true, classicCoverageConfirmed: false
        ) == .classicUnconfirmed)
        #expect(DiscoveryStatusIconState.current(
            isPaused: false, isScanning: true, classicCoverageConfirmed: true
        ) == .watching)
    }

    @Test func eachStatusHasDistinctSymbol() {
        let symbols = [
            DiscoveryStatusIconState.paused.symbolName,
            DiscoveryStatusIconState.attention.symbolName,
            DiscoveryStatusIconState.classicUnconfirmed.symbolName,
            DiscoveryStatusIconState.watching.symbolName
        ]
        #expect(Set(symbols).count == symbols.count)
    }
}
