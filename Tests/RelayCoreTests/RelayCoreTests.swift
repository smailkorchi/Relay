import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import RelayCore

final class RelayCoreTests: XCTestCase {
    private var fixture: URL!
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("RelayTests-\(UUID().uuidString)")
        source = fixture.appendingPathComponent("Sources")
        destination = fixture.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }

    private func makeFile(_ name: String, bytes: Int = 65_539) throws -> URL {
        let url = source.appendingPathComponent(name)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try data.write(to: url)
        return url
    }
    private func destinationNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: destination.path)
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func failSecondFile(_ request: TransferRequest) throws -> TransferRunFailure {
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.runForTesting(request, control: TransferControl()) { point in
            if case .beforeCopy(let index, _) = point, index == 2 {
                throw TransferFailure("Injected temporary write failure", code: EIO)
            }
        }) { stopped = $0 as? TransferRunFailure }
        return try XCTUnwrap(stopped)
    }

    private func failWithRetainedPartial(_ request: TransferRequest) throws -> TransferRunFailure {
        var stopped: TransferRunFailure?
        let attempts = AttemptBox()
        XCTAssertThrowsError(try TransferEngine.runForTesting(request, control: TransferControl()) { point in
            if case .beforeCopy(_, let attempt) = point { attempts.append(attempt) }
            if case .afterWrite = point { throw TransferFailure("Injected interrupted write", code: EIO) }
            if case .beforeIncompleteCleanup = point { throw TransferFailure("Injected unavailable cleanup", code: ENXIO) }
        }) { stopped = $0 as? TransferRunFailure }
        XCTAssertEqual(attempts.values, [1])
        return try XCTUnwrap(stopped)
    }

    func testBatchRoundTripKeepsOriginalsAndRecordsDigests() throws {
        let urls = try [makeFile("first.pkg"), makeFile("second.pkg", bytes: 18_021), makeFile("empty.pkg", bytes: 0)]
        let events = EventBox()
        let receipt = try TransferEngine.run(TransferRequest(sources: urls, destination: destination), control: TransferControl()) {
            events.append($0)
        }
        XCTAssertEqual(receipt.files.count, 3)
        for (index, file) in receipt.files.enumerated() {
            let original = try Data(contentsOf: urls[index])
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.destinationPath)), original)
            XCTAssertEqual(file.byteCount, Int64(original.count))
            XCTAssertEqual(file.sha256, sha(original))
            XCTAssertFalse(file.originalTrashed)
        }
        let finished = try XCTUnwrap(events.values.last)
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.verifiedFileCount, 3)
        XCTAssertEqual(finished.completedWorkBytes, finished.totalWorkBytes)
        XCTAssertEqual(finished.fractionCompleted, 1)
        XCTAssertEqual(Set(try destinationNames()), Set(urls.map(\.lastPathComponent)))
        XCTAssertTrue(events.values.contains { $0.fileIndex == 1 && $0.phase == .copying })
    }

    func testPreflightCollisionDoesNotCopyAnyBatchFiles() throws {
        let first = try makeFile("new.pkg")
        let second = try makeFile("existing.pkg")
        let existing = destination.appendingPathComponent("existing.pkg")
        let sentinel = Data("Keep this existing file".utf8)
        try sentinel.write(to: existing)
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination),
                                                  control: TransferControl(), progress: { _ in }))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try destinationNames(), ["existing.pkg"])
    }

    func testDuplicateBasenamesFailBeforeWriting() throws {
        let first = try makeFile("same.pkg")
        let otherFolder = fixture.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let second = otherFolder.appendingPathComponent("same.pkg")
        try Data("different".utf8).write(to: second)
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination),
                                                  control: TransferControl(), progress: { _ in }))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testCaseInsensitiveDestinationCollision() throws {
        let isCaseSensitive = try destination.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
        guard !isCaseSensitive else { throw XCTSkip("Fixture volume has case-sensitive names") }
        let first = try makeFile("Game.pkg")
        let otherFolder = fixture.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let second = otherFolder.appendingPathComponent("game.PKG")
        try Data("other".utf8).write(to: second)
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination),
                                                  control: TransferControl(), progress: { _ in }))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testSameFolderFoldersAndSymlinksAreRejected() throws {
        let file = try makeFile("source.pkg")
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: source),
                                                  control: TransferControl(), progress: { _ in }))
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [source], destination: destination),
                                                  control: TransferControl(), progress: { _ in }))
        let link = source.appendingPathComponent("link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [link], destination: destination),
                                                  control: TransferControl(), progress: { _ in }))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testCancellationDuringVerificationKeepsOriginalAndCleansPartial() throws {
        let file = try makeFile("cancel.pkg", bytes: 2 * 1024 * 1024)
        let control = TransferControl()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination,
                                                                  disposition: .trashAfterVerification), control: control) {
            if $0.phase == .verifying { control.cancel() }
        }) { XCTAssertTrue(($0 as? TransferRunFailure)?.isCancellation == true) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testCancellationKeepsCompletedVerifiedCopy() throws {
        let first = try makeFile("verified.pkg")
        let second = try makeFile("cancelled.pkg")
        let control = TransferControl()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination,
                                                                  disposition: .trashAfterVerification), control: control) {
            if $0.phase == .copying && $0.fileIndex == 2 { control.cancel() }
        }) { error in
            guard let failure = error as? TransferRunFailure else { return XCTFail("Missing partial receipt") }
            XCTAssertTrue(failure.isCancellation)
            XCTAssertEqual(failure.receipt.files.count, 1)
            XCTAssertEqual(failure.receipt.files.first?.sourcePath, first.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try destinationNames(), ["verified.pkg"])
    }

    func testCorruptedSavedDataIsNotPublishedOrTrashed() throws {
        let file = try makeFile("corruption.pkg")
        let folder = destination!
        let injection = Once()
        let events = EventBox()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination,
                                                                  disposition: .trashAfterVerification), control: TransferControl()) { event in
            events.append(event)
            if event.phase == .verifying && event.fileBytesDone == 0 {
                injection.run {
                    let temporary = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasPrefix(".relay-") || $0.lastPathComponent == file.lastPathComponent }!
                    let handle = try FileHandle(forWritingTo: temporary)
                    try handle.write(contentsOf: Data([0xAB, 0xCD, 0xEF]))
                    try handle.close()
                }
            }
        }) {
            XCTAssertTrue($0.localizedDescription.contains("verification") || $0.localizedDescription.contains("Verification failed"))
            XCTAssertTrue(($0 as? TransferRunFailure)?.isRetryable == false)
        }
        try injection.rethrowError()
        XCTAssertFalse(events.values.contains { $0.message.hasPrefix("Retrying") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testSourceMutationDuringCopyDoesNotTrash() throws {
        let file = try makeFile("changing.pkg")
        let mutation = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination,
                                                                  disposition: .trashAfterVerification), control: TransferControl()) { event in
            if event.phase == .copying {
                mutation.run { try Data("Changed source".utf8).write(to: file) }
            }
        })
        try mutation.rethrowError()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testEarlierSourceMutationPreventsAllBatchTrash() throws {
        let first = try makeFile("earlier.pkg")
        let second = try makeFile("later.pkg")
        let original = try Data(contentsOf: first)
        let mutation = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination,
                                                                  disposition: .trashAfterVerification), control: TransferControl()) { event in
            if event.verifiedFileCount == 1 && event.fileIndex == 1 {
                mutation.run { try Data("Changed after verification".utf8).write(to: first) }
            }
        }) { XCTAssertTrue($0.localizedDescription.contains("original changed")) }
        try mutation.rethrowError()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("earlier.pkg")), original)
        XCTAssertEqual(Set(try destinationNames()), ["earlier.pkg", "later.pkg"])
    }

    func testSourcesMoveToTrashOnlyAfterEntireBatchVerifies() throws {
        let urls = try [makeFile("relay-trash-\(UUID().uuidString).pkg"), makeFile("relay-trash-\(UUID().uuidString).pkg")]
        let allPresentAtVerification = Flag()
        let receipt = try TransferEngine.run(TransferRequest(sources: urls, destination: destination,
                                                           disposition: .trashAfterVerification), control: TransferControl()) { event in
            if event.phase == .verifying {
                if !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { allPresentAtVerification.set(false) }
            }
        }
        defer {
            for file in receipt.files {
                if let path = file.trashPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        XCTAssertTrue(allPresentAtVerification.value)
        XCTAssertTrue(receipt.files.allSatisfy(\.originalTrashed))
        XCTAssertTrue(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        for file in receipt.files {
            let path = try XCTUnwrap(file.trashPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertEqual(sha(try Data(contentsOf: URL(fileURLWithPath: path))), file.sha256)
        }
    }

    func testCancellationAfterOneTrashRetainsRecoveryReceipt() throws {
        let first = try makeFile("relay-trash-\(UUID().uuidString).pkg")
        let second = try makeFile("relay-trash-\(UUID().uuidString).pkg")
        let control = TransferControl()
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination,
                                                                  disposition: .trashAfterVerification), control: control) { event in
            if event.phase == .movingOriginals && event.message.hasPrefix("Moved 1 of") { control.cancel() }
        }) { stopped = $0 as? TransferRunFailure }
        let failure = try XCTUnwrap(stopped)
        defer {
            for file in failure.receipt.files {
                if let path = file.trashPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        XCTAssertTrue(failure.isCancellation)
        XCTAssertTrue(failure.localizedDescription.contains("1 originals were already moved to Trash"))
        XCTAssertEqual(failure.receipt.files.count, 2)
        XCTAssertTrue(failure.receipt.files[0].originalTrashed)
        XCTAssertNotNil(failure.receipt.files[0].trashPath)
        XCTAssertFalse(failure.receipt.files[1].originalTrashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testDestinationReplacementIsDetectedWithoutFallbackWrites() throws {
        let file = try makeFile("mount-change.pkg")
        let oldFolder = fixture.appendingPathComponent("DisconnectedDestination")
        let folder = destination!
        let change = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: folder), control: TransferControl()) { event in
            if event.phase == .copying {
                change.run {
                    try FileManager.default.moveItem(at: folder, to: oldFolder)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                }
            }
        })
        try change.rethrowError()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: oldFolder.path).isEmpty)
    }

    func testPublishedDestinationDeletionPreventsBatchTrashAndSuccess() throws {
        let first = try makeFile("already-verified.pkg")
        let second = try makeFile("later-file.pkg")
        let savedFirst = destination.appendingPathComponent(first.lastPathComponent)
        let deletion = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination,
                                                                  disposition: .trashAfterVerification), control: TransferControl()) { event in
            if event.phase == .copying && event.fileIndex == 2 {
                deletion.run { try FileManager.default.removeItem(at: savedFirst) }
            }
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("destination changed or disappeared"))
            XCTAssertEqual((error as? TransferRunFailure)?.receipt.files.count, 2)
        }
        try deletion.rethrowError()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testPublishedDestinationReplacementPreventsKeepBatchSuccess() throws {
        let first = try makeFile("already-verified.pkg")
        let second = try makeFile("later-file.pkg")
        let savedFirst = destination.appendingPathComponent(first.lastPathComponent)
        let replacement = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [first, second], destination: destination),
                                                  control: TransferControl()) { event in
            if event.phase == .copying && event.fileIndex == 2 {
                replacement.run { try Data("Changed after verification".utf8).write(to: savedFirst, options: .atomic) }
            }
        })
        try replacement.rethrowError()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testNewDestinationCollisionCannotBeOverwrittenDuringPublication() throws {
        let file = try makeFile("race.pkg")
        let final = destination.appendingPathComponent(file.lastPathComponent)
        let sentinel = Data("A file created by another process".utf8)
        let replacement = Once()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination),
                                                  control: TransferControl()) { event in
            if event.phase == .verifying && event.fileBytesDone == 0 {
                replacement.run {
                    if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
                    try sentinel.write(to: final)
                }
            }
        })
        try replacement.rethrowError()
        XCTAssertEqual(try Data(contentsOf: final), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try destinationNames(), [file.lastPathComponent])
    }

    func testSelectedDestinationIdentityIsRequiredAtStart() throws {
        let file = try makeFile("selected.pkg")
        let identity = try DestinationIdentity(folder: destination)
        let originalFolder = fixture.appendingPathComponent("OldSelection")
        try FileManager.default.moveItem(at: destination, to: originalFolder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination,
                                                                  expectedDestination: identity), control: TransferControl(), progress: { _ in }))
        XCTAssertThrowsError(try DiskBenchmark.run(at: destination, byteCount: 1024,
                                                  expectedDestination: identity, control: TransferControl(), progress: { _ in }))
        XCTAssertTrue(try destinationNames().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: originalFolder.path).isEmpty)
    }

    func testOptionalExternalVolumeRoundTrip() throws {
        guard let volumePath = ProcessInfo.processInfo.environment["RELAY_TEST_VOLUME"] else {
            throw XCTSkip("Set RELAY_TEST_VOLUME and RELAY_TEST_VOLUME_UUID to run the explicit external-drive fixture")
        }
        guard let expectedUUID = ProcessInfo.processInfo.environment["RELAY_TEST_VOLUME_UUID"],
              UUID(uuidString: expectedUUID) != nil else {
            throw TransferFailure("Set RELAY_TEST_VOLUME_UUID to the selected external volume's UUID")
        }
        let volume = URL(fileURLWithPath: volumePath, isDirectory: true).standardizedFileURL
        let resources = try volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsInternalKey, .volumeURLKey])
        guard resources.volumeUUIDString?.uppercased() == expectedUUID.uppercased(),
              resources.volumeIsInternal == false,
              resources.volume?.standardizedFileURL.path == volume.path else {
            throw TransferFailure("External fixture refused: select the authorized external volume's mount point and UUID")
        }
        let volumeIdentity = try DestinationIdentity(folder: volume)
        let ownedFolder = volume.appendingPathComponent(".relay-fixture-\(UUID().uuidString)", isDirectory: true)
        // Only this UUID-named fixture directory is ever created or removed on the selected volume.
        try FileManager.default.createDirectory(at: ownedFolder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: ownedFolder) }
        XCTAssertEqual(try DestinationIdentity(folder: volume), volumeIdentity)
        let file = try makeFile("relay-roundtrip-\(UUID().uuidString).pkg", bytes: 16 * 1024 * 1024 + 31)
        let outbound = try TransferEngine.run(TransferRequest(sources: [file], destination: ownedFolder,
                                                            expectedDestination: DestinationIdentity(folder: ownedFolder)),
                                              control: TransferControl(), progress: { _ in })
        let saved = URL(fileURLWithPath: try XCTUnwrap(outbound.files.first?.destinationPath))
        let inbound = try TransferEngine.run(TransferRequest(sources: [saved], destination: destination,
                                                           expectedDestination: DestinationIdentity(folder: destination)),
                                             control: TransferControl(), progress: { _ in })
        let restored = URL(fileURLWithPath: try XCTUnwrap(inbound.files.first?.destinationPath))
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: restored))
        XCTAssertEqual(outbound.files.first?.sha256, inbound.files.first?.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        let cancelled = TransferControl()
        XCTAssertThrowsError(try DiskBenchmark.run(at: ownedFolder, byteCount: 16 * 1024 * 1024,
                                                  expectedDestination: DestinationIdentity(folder: ownedFolder), control: cancelled) { _ in cancelled.cancel() })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedFolder.path), [file.lastPathComponent])
    }

    func testBenchmarkVerifiesDataAndAlwaysRemovesTemporaryFile() throws {
        let result = try DiskBenchmark.run(at: destination, byteCount: 2 * 1024 * 1024 + 7,
                                           control: TransferControl(), progress: { _ in })
        XCTAssertEqual(result.testedBytes, 2 * 1024 * 1024 + 7)
        XCTAssertGreaterThan(result.readBytesPerSecond, 0)
        XCTAssertGreaterThan(result.writeBytesPerSecond, 0)
        XCTAssertTrue(try destinationNames().isEmpty)
        let control = TransferControl()
        XCTAssertThrowsError(try DiskBenchmark.run(at: destination, byteCount: 1024 * 1024, control: control) { _ in control.cancel() })
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testBenchmarkCorruptionFailsAndCleansTemporaryFile() throws {
        let folder = destination!
        let mutation = Once()
        XCTAssertThrowsError(try DiskBenchmark.run(at: folder, byteCount: 1024 * 1024,
                                                  control: TransferControl()) { message in
            if message.hasPrefix("Measuring read") {
                mutation.run {
                    let file = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasPrefix(".relay-speed-") }!
                    try Data("Corrupt".utf8).write(to: file)
                }
            }
        })
        try mutation.rethrowError()
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testTransientWriteErrorsRetryAtMostTwiceAndVerify() throws {
        let file = try makeFile("retry.pkg", bytes: 2 * 1024 * 1024 + 1)
        let attempts = AttemptBox()
        let events = EventBox()
        let receipt = try TransferEngine.runForTesting(TransferRequest(sources: [file], destination: destination),
                                                       control: TransferControl(), progress: { events.append($0) }) { point in
            if case .beforeCopy(_, let attempt) = point { attempts.append(attempt) }
            if case .afterWrite(_, let attempt, _) = point, attempt < 3 {
                throw TransferFailure("Injected transient write failure", code: EIO)
            }
        }
        XCTAssertEqual(attempts.values, [1, 2, 3])
        XCTAssertEqual(events.values.filter { $0.message.hasPrefix("Retrying") }.count, 2)
        XCTAssertEqual(receipt.files.first?.sha256, sha(try Data(contentsOf: file)))
        XCTAssertEqual(try destinationNames(), [file.lastPathComponent])
    }

    func testTransientFailureStopsAfterThirdAttemptWithRecovery() throws {
        let file = try makeFile("bounded.pkg")
        let attempts = AttemptBox()
        XCTAssertThrowsError(try TransferEngine.runForTesting(TransferRequest(sources: [file], destination: destination),
                                                            control: TransferControl()) { point in
            if case .beforeCopy(_, let attempt) = point {
                attempts.append(attempt)
                throw TransferFailure("Injected timeout", code: ETIMEDOUT)
            }
        }) { error in
            let failure = error as? TransferRunFailure
            XCTAssertTrue(failure?.isRetryable == true)
            XCTAssertNotNil(failure?.recovery)
            XCTAssertEqual(failure?.receipt.files.count, 0)
        }
        XCTAssertEqual(attempts.values, [1, 2, 3])
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testPermissionFailureNeverAutomaticallyRetries() throws {
        let file = try makeFile("permission.pkg")
        let attempts = AttemptBox()
        let request = TransferRequest(sources: [file], destination: destination)
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.runForTesting(request,
                                                            control: TransferControl()) { point in
            if case .beforeCopy(_, let attempt) = point {
                attempts.append(attempt)
                throw TransferFailure("Injected permission failure", code: EACCES)
            }
        }) { stopped = $0 as? TransferRunFailure }
        XCTAssertTrue(stopped?.isRetryable == true)
        XCTAssertEqual(attempts.values, [1])
        XCTAssertTrue(try destinationNames().isEmpty)
        let receipt = try TransferEngine.run(request, recovery: XCTUnwrap(stopped?.recovery),
                                             control: TransferControl(), progress: { _ in })
        XCTAssertEqual(receipt.files.count, 1)
    }

    func testNoSpaceNeverAutomaticallyRetriesButCanResumeAfterRepair() throws {
        let first = try makeFile("verified-before-full.pkg")
        let second = try makeFile("no-space.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let attempts = AttemptBox()
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.runForTesting(request, control: TransferControl()) { point in
            if case .beforeCopy(let index, _) = point, index == 2 {
                attempts.append(index)
                throw TransferFailure("Injected full destination", code: ENOSPC)
            }
        }) { stopped = $0 as? TransferRunFailure }
        let failure = try XCTUnwrap(stopped)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(attempts.values, [2])
        XCTAssertEqual(failure.receipt.files.count, 1)
        let retryAttempts = AttemptBox()
        let receipt = try TransferEngine.runForTesting(request, recovery: XCTUnwrap(failure.recovery),
                                                       control: TransferControl()) { point in
            if case .beforeCopy(let index, _) = point { retryAttempts.append(index) }
        }
        XCTAssertEqual(retryAttempts.values, [2])
        XCTAssertEqual(receipt.files.count, 2)
        XCTAssertEqual(receipt.id, failure.receipt.id)
    }

    func testOfflineFailureAllowsManualRetryWithoutAutomaticAttempts() throws {
        let file = try makeFile("offline.pkg")
        let attempts = AttemptBox()
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.runForTesting(TransferRequest(sources: [file], destination: destination),
                                                            control: TransferControl()) { point in
            if case .beforeCopy(_, let attempt) = point {
                attempts.append(attempt)
                throw TransferFailure("Device not configured", code: ENXIO)
            }
        }) { stopped = $0 as? TransferRunFailure }
        XCTAssertEqual(attempts.values, [1])
        XCTAssertTrue(stopped?.isRetryable == true)
        XCTAssertNotNil(stopped?.recovery)
    }

    func testManualRetryReusesVerifiedFilesAndStableReceipt() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let stopped = try failSecondFile(request)
        let savedFirst = destination.appendingPathComponent(first.lastPathComponent)
        let originalSavedIdentity = try FileIdentity(path: savedFirst.path)
        let events = EventBox()
        let attempts = AttemptBox()
        let receipt = try TransferEngine.runForTesting(request, recovery: XCTUnwrap(stopped.recovery),
                                                       control: TransferControl(), progress: { events.append($0) }) { point in
            if case .beforeCopy(let index, _) = point { attempts.append(index) }
        }
        XCTAssertEqual(attempts.values, [2])
        XCTAssertFalse(events.values.contains { ($0.phase == .copying || $0.phase == .verifying) && $0.fileIndex == 1 })
        XCTAssertEqual(try FileIdentity(path: savedFirst.path), originalSavedIdentity)
        XCTAssertEqual(receipt.id, stopped.receipt.id)
        XCTAssertEqual(receipt.startedAt, stopped.receipt.startedAt)
        XCTAssertEqual(receipt.files.count, 2)
    }

    func testChangedVerifiedDestinationPreventsManualRetry() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let stopped = try failSecondFile(request)
        let savedFirst = destination.appendingPathComponent(first.lastPathComponent)
        let changed = Data("Changed saved copy".utf8)
        try changed.write(to: savedFirst)
        XCTAssertThrowsError(try TransferEngine.run(request, recovery: XCTUnwrap(stopped.recovery),
                                                  control: TransferControl(), progress: { _ in })) {
            XCTAssertTrue(($0 as? TransferRunFailure)?.isRetryable == false)
        }
        XCTAssertEqual(try Data(contentsOf: savedFirst), changed)
        XCTAssertEqual(try destinationNames(), [first.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testChangedSourceAndRequestPreventRecovery() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let stopped = try failSecondFile(request)
        let recovery = try XCTUnwrap(stopped.recovery)
        let changedPolicy = TransferRequest(sources: [first, second], destination: destination, disposition: .trashAfterVerification)
        XCTAssertThrowsError(try TransferEngine.run(changedPolicy, recovery: recovery, control: TransferControl(), progress: { _ in }))
        try Data("Changed original".utf8).write(to: first)
        XCTAssertThrowsError(try TransferEngine.run(request, recovery: recovery, control: TransferControl(), progress: { _ in }))
        XCTAssertEqual(try destinationNames(), [first.lastPathComponent])
    }

    func testTrashFailureCanResumeCleanupWithoutRecopyingOrReopeningTrashedSource() throws {
        let first = try makeFile("relay-trash-\(UUID().uuidString).pkg")
        let second = try makeFile("relay-trash-\(UUID().uuidString).pkg")
        let request = TransferRequest(sources: [first, second], destination: destination, disposition: .trashAfterVerification)
        var stopped: TransferRunFailure?
        XCTAssertThrowsError(try TransferEngine.runForTesting(request, control: TransferControl()) { point in
            if case .beforeTrash(let index) = point, index == 2 { throw TransferFailure("Injected Trash permission error", code: EACCES) }
        }) { stopped = $0 as? TransferRunFailure }
        let failure = try XCTUnwrap(stopped)
        var trashedPaths = failure.receipt.files.compactMap(\.trashPath)
        defer { for path in Set(trashedPaths) { try? FileManager.default.removeItem(atPath: path) } }
        XCTAssertTrue(failure.isRetryable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let attempts = AttemptBox()
        let receipt = try TransferEngine.runForTesting(request, recovery: XCTUnwrap(failure.recovery),
                                                       control: TransferControl()) { point in
            if case .beforeCopy(let index, _) = point { attempts.append(index) }
        }
        trashedPaths += receipt.files.compactMap(\.trashPath)
        XCTAssertTrue(attempts.values.isEmpty)
        XCTAssertTrue(receipt.files.allSatisfy(\.originalTrashed))
        XCTAssertEqual(receipt.files[0].trashPath, failure.receipt.files[0].trashPath)
        XCTAssertEqual(receipt.id, failure.receipt.id)
    }

    func testCancellationDuringRetryBackoffIsPrompt() throws {
        let file = try makeFile("backoff.pkg")
        let control = TransferControl()
        let attempts = AttemptBox()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try TransferEngine.runForTesting(TransferRequest(sources: [file], destination: destination),
                                                            control: control, progress: { event in
            if event.message.hasPrefix("Retrying") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { control.cancel() } }
        }) { point in
            if case .beforeCopy(_, let attempt) = point {
                attempts.append(attempt)
                throw TransferFailure("Injected busy device", code: EBUSY)
            }
        }) { XCTAssertTrue(($0 as? TransferRunFailure)?.isCancellation == true) }
        XCTAssertTrue(ProcessInfo.processInfo.systemUptime - started < 0.3)
        XCTAssertEqual(attempts.values, [1])
        XCTAssertTrue(try destinationNames().isEmpty)
    }

    func testImmediateCancellationStillAllowsFreshRetry() throws {
        let file = try makeFile("early-cancel.pkg")
        let control = TransferControl(); control.cancel()
        XCTAssertThrowsError(try TransferEngine.run(TransferRequest(sources: [file], destination: destination),
                                                  control: control, progress: { _ in })) {
            XCTAssertTrue(($0 as? TransferRunFailure)?.isCancellation == true)
            XCTAssertTrue(($0 as? TransferRunFailure)?.isRetryable == true)
            XCTAssertEqual(($0 as? TransferRunFailure)?.receipt.files.count, 0)
        }
    }

    func testUnchangedReboundDoesNotReadVerifiedFilesAgain() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let failure = try failSecondFile(request)
        let events = EventBox()
        let rebound = try XCTUnwrap(failure.recovery).rebound(to: destination,
                                                            expectedDestination: DestinationIdentity(folder: destination),
                                                            control: TransferControl(), progress: { events.append($0) })
        XCTAssertFalse(events.values.contains { $0.phase == .verifying })
        let receipt = try TransferEngine.run(request, recovery: rebound, control: TransferControl(), progress: { _ in })
        XCTAssertEqual(receipt.id, failure.receipt.id)
    }

    func testForcedReconnectVerificationChecksSourcesAndCopiesAndRejectsCorruption() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let failure = try failSecondFile(TransferRequest(sources: [first, second], destination: destination))
        let recovery = try XCTUnwrap(failure.recovery)
        let events = EventBox()
        _ = try recovery.rebound(to: destination, expectedDestination: DestinationIdentity(folder: destination),
                                forceVerification: true, control: TransferControl(), progress: { events.append($0) })
        XCTAssertTrue(events.values.contains { $0.message.contains("verified source") })
        XCTAssertTrue(events.values.contains { $0.message.contains("copies after reconnecting") })
        let saved = destination.appendingPathComponent(first.lastPathComponent)
        let originalDate = try saved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data(repeating: 0x55, count: Int(failure.receipt.files[0].byteCount)).write(to: saved)
        if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: saved.path) }
        XCTAssertThrowsError(try recovery.rebound(to: destination, expectedDestination: DestinationIdentity(folder: destination),
                                                 forceVerification: true, control: TransferControl(), progress: { _ in })) {
            XCTAssertTrue(($0 as? TransferRunFailure)?.isRetryable == false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testReboundRejectsChangedSourceAndDifferentFolder() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let failure = try failSecondFile(TransferRequest(sources: [first, second], destination: destination))
        let recovery = try XCTUnwrap(failure.recovery)
        let other = fixture.appendingPathComponent("OtherDestination")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertThrowsError(try recovery.rebound(to: other, expectedDestination: DestinationIdentity(folder: other),
                                                 control: TransferControl(), progress: { _ in }))
        try Data("Changed original".utf8).write(to: first)
        XCTAssertThrowsError(try recovery.rebound(to: destination, expectedDestination: DestinationIdentity(folder: destination),
                                                 control: TransferControl(), progress: { _ in }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    func testReboundToReplacementFolderRehashesSavedCopyBeforeResume() throws {
        let first = try makeFile("reused.pkg")
        let second = try makeFile("unfinished.pkg")
        let request = TransferRequest(sources: [first, second], destination: destination)
        let failure = try failSecondFile(request)
        let priorFolder = fixture.appendingPathComponent("PriorDestination")
        try FileManager.default.moveItem(at: destination, to: priorFolder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: priorFolder.appendingPathComponent(first.lastPathComponent),
                                         to: destination.appendingPathComponent(first.lastPathComponent))
        let events = EventBox()
        let rebound = try XCTUnwrap(failure.recovery).rebound(to: destination,
                                                            expectedDestination: DestinationIdentity(folder: destination),
                                                            control: TransferControl(), progress: { events.append($0) })
        XCTAssertTrue(events.values.contains { $0.phase == .verifying })
        let receipt = try TransferEngine.run(request, recovery: rebound, control: TransferControl(), progress: { _ in })
        XCTAssertEqual(receipt.files.count, 2)
        XCTAssertEqual(receipt.id, failure.receipt.id)
    }

    func testRemountFingerprintOnlyIgnoresDeviceNumber() throws {
        let file = try makeFile("fingerprint.pkg")
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        let original = FileIdentity(info)
        info.st_dev = info.st_dev == 0 ? 1 : 0
        let remounted = FileIdentity(info)
        XCTAssertFalse(original == remounted)
        XCTAssertTrue(original.matchesIgnoringDevice(remounted))
        info.st_ino += 1
        XCTAssertFalse(original.matchesIgnoringDevice(FileIdentity(info)))
    }

    func testOwnedIncompleteCopyIsReclaimedBeforeManualRetry() throws {
        let file = try makeFile("interrupted.pkg")
        let request = TransferRequest(sources: [file], destination: destination)
        let failure = try failWithRetainedPartial(request)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(try destinationNames().count, 1)
        let recovery = try XCTUnwrap(failure.recovery).rebound(to: destination,
                                                             expectedDestination: DestinationIdentity(folder: destination),
                                                             control: TransferControl(), progress: { _ in })
        XCTAssertTrue(try destinationNames().isEmpty)
        let receipt = try TransferEngine.run(request, recovery: recovery, control: TransferControl(), progress: { _ in })
        XCTAssertEqual(receipt.files.count, 1)
        XCTAssertEqual(receipt.id, failure.receipt.id)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(file.lastPathComponent)), try Data(contentsOf: file))
    }

    func testModifiedOwnedIncompleteCopyIsPreserved() throws {
        let file = try makeFile("interrupted.pkg")
        let failure = try failWithRetainedPartial(TransferRequest(sources: [file], destination: destination))
        let partial = destination.appendingPathComponent(try XCTUnwrap(destinationNames().first))
        let changed = Data("An externally modified partial".utf8)
        try changed.write(to: partial)
        XCTAssertThrowsError(try XCTUnwrap(failure.recovery).rebound(to: destination,
                                                                   expectedDestination: DestinationIdentity(folder: destination),
                                                                   control: TransferControl(), progress: { _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("new empty destination folder"))
            XCTAssertTrue(($0 as? TransferRunFailure)?.isRetryable == false)
        }
        XCTAssertEqual(try Data(contentsOf: partial), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testReplacedOwnedIncompleteCopyIsPreserved() throws {
        let file = try makeFile("interrupted.pkg")
        let failure = try failWithRetainedPartial(TransferRequest(sources: [file], destination: destination))
        let partial = destination.appendingPathComponent(try XCTUnwrap(destinationNames().first))
        let replacement = Data("A replacement file".utf8)
        try replacement.write(to: partial, options: .atomic)
        XCTAssertThrowsError(try XCTUnwrap(failure.recovery).rebound(to: destination,
                                                                   expectedDestination: DestinationIdentity(folder: destination),
                                                                   control: TransferControl(), progress: { _ in }))
        XCTAssertEqual(try Data(contentsOf: partial), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TransferEvent] = []
    func append(_ event: TransferEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var values: [TransferEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var performed = false
    private var failure: Error?
    func run(_ action: () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !performed else { return }
        performed = true
        do { try action() } catch { failure = error }
    }
    func rethrowError() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = true
    func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class AttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    func append(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
}
