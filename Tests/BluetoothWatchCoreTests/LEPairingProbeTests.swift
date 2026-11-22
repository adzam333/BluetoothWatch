import Testing
@testable import BluetoothWatchCore

struct LEPairingProbeTests {
    private func candidate(_ service: String, _ characteristic: String, readable: Bool = true, index: Int = 0) -> LEPairingProbe.Candidate {
        LEPairingProbe.Candidate(instanceIndex: index, serviceUUID: service, characteristicUUID: characteristic, isReadable: readable)
    }

    @Test func testSkipsOpenServicesAndUnreadableCharacteristics() {
        var probe = LEPairingProbe(candidates: [
            candidate("1800", "2A00"),
            candidate("180a", "2A29"),
            candidate("FFF0", "FFF1", readable: false),
            candidate("fff0", "fff2")
        ])
        #expect(probe.start(pairedEvidence: false) == .read(candidate("FFF0", "FFF2")))
        #expect(probe.readsAttempted == 1)
    }

    @Test func testNoUsableCharacteristicsHandsOffToSettings() {
        var probe = LEPairingProbe(candidates: [candidate("1800", "2A00")])
        #expect(!probe.hasCandidates)
        guard case .finish(.settingsRequired(let reason)) = probe.start(pairedEvidence: false) else {
            Issue.record("Expected settings handoff")
            return
        }
        #expect(reason.contains("nothing"))
    }

    @Test func testSuccessfulReadsWithoutEvidenceNeverClaimPaired() {
        var probe = LEPairingProbe(candidates: [candidate("FFF0", "FFF1"), candidate("FFF0", "FFF2")])
        #expect(probe.start(pairedEvidence: false) == .read(candidate("FFF0", "FFF1")))
        #expect(probe.record(.success, pairedEvidence: false) == .read(candidate("FFF0", "FFF2")))
        guard case .finish(.settingsRequired(let reason)) = probe.record(.success, pairedEvidence: false) else {
            Issue.record("A successful read alone must not count as pairing")
            return
        }
        #expect(reason.contains("did not request or confirm pairing"))
    }

    @Test func testPairedEvidenceFinishesAsPaired() {
        var probe = LEPairingProbe(candidates: [candidate("FFF0", "FFF1"), candidate("FFF0", "FFF2")])
        _ = probe.start(pairedEvidence: false)
        #expect(probe.record(.success, pairedEvidence: true) == .finish(.paired))
    }

    @Test func testExistingEvidenceAtStartFinishesWithoutReading() {
        var probe = LEPairingProbe(candidates: [candidate("FFF0", "FFF1")])
        #expect(probe.start(pairedEvidence: true) == .finish(.paired))
        #expect(probe.readsAttempted == 0)
    }

    @Test func testSecurityFailureStopsWithFailureNotSettings() {
        var probe = LEPairingProbe(candidates: [candidate("FFF0", "FFF1"), candidate("FFF0", "FFF2")])
        _ = probe.start(pairedEvidence: false)
        guard case .finish(.failed(let reason)) = probe.record(.securityRequired, pairedEvidence: false) else {
            Issue.record("A declined or failed macOS prompt must be reported as a failure")
            return
        }
        #expect(reason.contains("not completed"))
    }

    @Test func testRemovedPairingKeysAreReported() {
        var probe = LEPairingProbe(candidates: [candidate("FFF0", "FFF1")])
        _ = probe.start(pairedEvidence: false)
        guard case .finish(.failed(let reason)) = probe.record(.pairingRemoved, pairedEvidence: false) else {
            Issue.record("Expected failure")
            return
        }
        #expect(reason.contains("Remove it"))
    }

    @Test func testUnrelatedErrorsContinueToNextCandidate() {
        var probe = LEPairingProbe(candidates: [
            candidate("FFF0", "FFF1"), candidate("FFF0", "FFF2"), candidate("FFF0", "FFF3")
        ])
        _ = probe.start(pairedEvidence: false)
        #expect(probe.record(.notPermitted, pairedEvidence: false) == .read(candidate("FFF0", "FFF2")))
        #expect(probe.record(.otherError("x"), pairedEvidence: false) == .read(candidate("FFF0", "FFF3")))
    }

    @Test func testDuplicateUUIDsRetainDistinctCharacteristicInstances() {
        let skipped = candidate("1800", "2A00", index: 0)
        let first = candidate("FFF0", "FFF1", index: 1)
        let second = candidate("FFF0", "FFF1", index: 2)
        var probe = LEPairingProbe(candidates: [skipped, first, second])

        #expect(probe.start(pairedEvidence: false) == .read(first))
        #expect(probe.record(.success, pairedEvidence: false) == .read(second))
        #expect(probe.record(.securityRequired, pairedEvidence: false) == .finish(
            .failed("macOS requested pairing, but it was not completed (declined, timed out, or rejected by the device). Retry, or use Bluetooth settings.")
        ))
    }

    @Test func testReadsAreBounded() {
        let many = (0..<20).map { candidate("FFF0", String(format: "FF%02X", $0)) }
        var probe = LEPairingProbe(candidates: many, maxReads: 3)
        var step = probe.start(pairedEvidence: false)
        var reads = 0
        while case .read = step {
            reads += 1
            step = probe.record(.success, pairedEvidence: false)
        }
        #expect(reads == 3)
        guard case .finish(.settingsRequired) = step else {
            Issue.record("Expected settings handoff after the read limit")
            return
        }
    }

    @Test func testClassifiesCoreBluetoothErrors() {
        typealias R = LEPairingProbe.ReadResult
        #expect(R.classify(domain: nil, code: 0) == .success)
        #expect(R.classify(domain: "CBATTErrorDomain", code: 0x05) == .securityRequired)
        #expect(R.classify(domain: "CBATTErrorDomain", code: 0x0C) == .securityRequired)
        #expect(R.classify(domain: "CBATTErrorDomain", code: 0x0F) == .securityRequired)
        #expect(R.classify(domain: "CBATTErrorDomain", code: 0x02) == .notPermitted)
        #expect(R.classify(domain: "CBATTErrorDomain", code: 0x08) == .notPermitted)
        #expect(R.classify(domain: "CBErrorDomain", code: 14) == .pairingRemoved)
        #expect(R.classify(domain: "CBErrorDomain", code: 15) == .securityRequired)
        #expect(R.classify(domain: "CBErrorDomain", code: 7) == .otherError("CBErrorDomain 7"))
    }
}

struct LEPairingEvidenceTests {
    private typealias Paired = LEPairingEvidence.PairedDevice

    @Test func testNewMatchingPairedDeviceIsEvidence() {
        #expect(LEPairingEvidence.isNewPairing(
            before: ["aa:aa:aa:aa:aa:aa"],
            after: [Paired(address: "aa:aa:aa:aa:aa:aa", name: "Old"), Paired(address: "BB-BB-BB-BB-BB-BB", name: " Sensor ")],
            deviceName: "sensor"
        ))
    }

    @Test func testUnchangedPairedListIsNotEvidence() {
        #expect(!LEPairingEvidence.isNewPairing(
            before: ["AA-AA-AA-AA-AA-AA"],
            after: [Paired(address: "aa:aa:aa:aa:aa:aa", name: "Sensor")],
            deviceName: "Sensor"
        ))
    }

    @Test func testUnrelatedNewPairingWithDifferentNameIsNotEvidence() {
        #expect(!LEPairingEvidence.isNewPairing(
            before: [],
            after: [Paired(address: "bb:bb:bb:bb:bb:bb", name: "Headphones")],
            deviceName: "Sensor"
        ))
    }

    @Test func testNewPairingCountsWhenANameIsUnknown() {
        #expect(LEPairingEvidence.isNewPairing(
            before: [], after: [Paired(address: "bb:bb:bb:bb:bb:bb", name: nil)], deviceName: "Sensor"
        ))
        #expect(LEPairingEvidence.isNewPairing(
            before: [], after: [Paired(address: "bb:bb:bb:bb:bb:bb", name: "Sensor")], deviceName: nil
        ))
        #expect(!LEPairingEvidence.isNewPairing(
            before: [], after: [Paired(address: "", name: "Sensor")], deviceName: "Sensor"
        ))
    }
}
