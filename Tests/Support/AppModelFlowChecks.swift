import AppKit
import Combine
import CryptoKit
import Foundation
import RelayCore

private struct FlowCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct AppModelFlowRunner {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let checks = AppModelFlowChecks(receiptsDirectory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: checks.internalFixture, withIntermediateDirectories: false)
            await checks.run("Setup navigation and empty-selection gates", checks.checkNavigation)
            if ProcessInfo.processInfo.environment["RELAY_TEST_VOLUME"] != nil {
                try checks.prepareExternalFixture()
                await checks.run("Real transfer: setup → progress → success", checks.checkSuccessfulTransfer)
                await checks.run("Immediate cancellation → recovery → retry → success", checks.checkImmediateCancellation)
                await checks.run("Partial batch cancellation → verified-copy resume", checks.checkPartialResume)
            } else {
                checks.skipped = 3
                print("SKIP 3 external-source integration cases: set RELAY_TEST_VOLUME and RELAY_TEST_VOLUME_UUID to an authorized external volume")
            }
        } catch {
            checks.failures += 1
            print("FAIL fixture preparation: \(error)")
        }
        await checks.cleanUp()
        print("\(checks.passed) flow cases passed; \(checks.skipped) skipped; \(checks.assertions) assertions; \(checks.failures) failures")
        exit(checks.failures == 0 ? 0 : 1)
    }
}

@MainActor
private final class AppModelFlowChecks {
    let internalFixture = FileManager.default.temporaryDirectory.appendingPathComponent("RelayAppFlow-\(UUID().uuidString)", isDirectory: true)
    private let externalName = ".relay-app-flow-\(UUID().uuidString)"
    private var externalVolume: URL?
    private var externalFixture: URL?
    private let receiptsDirectory: URL
    private var models: [AppModel] = []
    var passed = 0
    var skipped = 0
    var assertions = 0
    var failures = 0

    init(receiptsDirectory: URL) { self.receiptsDirectory = receiptsDirectory }

    func run(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failures += 1
            print("FAIL \(name): \(error)")
        }
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw FlowCheckFailure(message) }
    }

    func prepareExternalFixture() throws {
        guard let expectedUUID = ProcessInfo.processInfo.environment["RELAY_TEST_VOLUME_UUID"],
              UUID(uuidString: expectedUUID) != nil else {
            throw FlowCheckFailure("Set RELAY_TEST_VOLUME_UUID to the selected external volume's UUID before running external checks")
        }
        let volume = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELAY_TEST_VOLUME"]!, isDirectory: true).standardizedFileURL
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", volume.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              (info["VolumeUUID"] as? String)?.uppercased() == expectedUUID.uppercased(),
              info["Internal"] as? Bool == false,
              let mountPoint = info["MountPoint"] as? String,
              URL(fileURLWithPath: mountPoint).standardizedFileURL.path == volume.path else {
            throw FlowCheckFailure("External fixture refused: the selected mounted volume does not match the authorized external UUID")
        }
        let fixture = volume.appendingPathComponent(externalName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: fixture.path),
              !FileManager.default.fileExists(atPath: volume.appendingPathComponent("._" + externalName).path) else {
            throw FlowCheckFailure("The unique external fixture name already exists")
        }
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        externalVolume = volume
        externalFixture = fixture
        print("Authorized external fixture: \(fixture.path)")
    }

    func checkNavigation() async throws {
        let model = makeModel()
        try require(model.page == .direction && model.setupStep == 1, "New model must open at Direction")
        try require(model.canContinue && !model.canGoBack, "Direction must allow Continue without a Back action")
        model.continueSetup()
        try require(model.page == .files && !model.canContinue, "Files must gate Continue when empty")
        model.continueSetup()
        try require(model.page == .files, "Empty Files Continue must not advance")
        model.showSetupStep(.review)
        try require(model.page == .files, "Review must be blocked without files and destination")
        model.showSetupStep(.destination)
        try require(model.page == .files, "Destination must be blocked without files")
        let file = internalFixture.appendingPathComponent("navigation-source.pkg")
        try makeFile(file, bytes: 17, seed: 11)
        model.addFiles([file])
        try require(model.files.count == 1 && model.canContinue, "Adding a Mac source must enable Files Continue")
        model.continueSetup()
        try require(model.page == .destination && !model.canContinue, "Destination must gate Continue without a selection")
        model.goBack()
        try require(model.page == .files && model.navigationDirection == -1, "Back must return to Files")
        model.newTransfer()
        try require(model.page == .direction && model.files.isEmpty && model.destination == nil, "New Transfer must reset the selection and page")
    }

    func checkSuccessfulTransfer() async throws {
        let (model, sources, destination) = try await prepareTransfer("success", sizes: [1_048_607])
        try require(model.page == .review && model.canContinue, "Prepared batch must reach Review")
        model.goBack()
        try require(model.page == .destination, "Review Back must preserve destination selection")
        model.continueSetup()
        try require(model.page == .review, "Destination Continue must return to Review")
        model.continueSetup()
        try require(model.page == .progress && model.isTransferring && !model.canGoBack, "Transfer must enter its dedicated progress page")
        model.showSetupStep(.files)
        try require(model.page == .progress, "Setup navigation must stay blocked during transfer")
        try await waitForFinish(model)
        try require(model.page == .success && model.completed, "Real transfer must end on Success")
        try require(model.verifiedCount == 1 && model.lastReceipt?.files.count == 1, "Success must report one verified file")
        try verifyCopies(sources: sources, destination: destination, model: model)
        try archiveReceipt(model, label: "success")
    }

    func checkImmediateCancellation() async throws {
        let (model, sources, destination) = try await prepareTransfer("early-cancel", sizes: [64 * 1024 * 1024])
        model.continueSetup()
        model.cancelTransfer()
        try require(model.statusMessage == "Stopping safely…", "Cancellation must immediately acknowledge safe stopping")
        try await waitForFinish(model)
        try require(model.page == .recovery && model.isCancelled, "Immediate cancellation must reach Recovery")
        try require(model.verifiedCount == 0, "Early cancellation must not invent a verified file")
        try require(model.canRetry && model.retryAvailable, "Cancellation before the first completed copy must permit a fresh retry")
        try require(FileManager.default.fileExists(atPath: sources[0].path), "Cancellation must preserve its source")
        try require(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Early cancellation must clean its incomplete destination")
        model.retryTransfer()
        try require(model.page == .progress && model.isTransferring, "Retry must reopen Progress")
        try await waitForFinish(model)
        try require(model.page == .success && model.verifiedCount == 1, "Early-cancel retry must complete successfully")
        try verifyCopies(sources: sources, destination: destination, model: model)
        try archiveReceipt(model, label: "early-cancel-retry")
    }

    func checkPartialResume() async throws {
        let (model, sources, destination) = try await prepareTransfer("partial-resume", sizes: [1_048_607, 64 * 1024 * 1024])
        var requestedCancellation = false
        let cancellation = model.$event.sink { event in
            guard model.isTransferring, !requestedCancellation, event?.verifiedFileCount == 1 else { return }
            requestedCancellation = true
            model.cancelTransfer()
        }
        model.continueSetup()
        try await waitForFinish(model)
        cancellation.cancel()
        try require(requestedCancellation, "The first verified-copy event must be observed before cancellation")
        try require(model.page == .recovery && model.isCancelled && model.verifiedCount == 1, "Partial cancellation must preserve exactly its first verified copy")
        try require(model.canRetry && model.isResuming, "Partial cancellation must retain a valid resume context")
        let firstCopy = destination.appendingPathComponent(sources[0].lastPathComponent)
        let initialInode = try FileManager.default.attributesOfItem(atPath: firstCopy.path)[.systemFileNumber] as? NSNumber
        try require(initialInode != nil, "The already verified destination file must exist")
        try archiveReceipt(model, label: "partial-cancel")
        var observedLiveVerifiedCount = 0
        let progress = model.$event.sink { _ in
            if model.isTransferring { observedLiveVerifiedCount = max(observedLiveVerifiedCount, model.verifiedCount) }
        }
        model.retryTransfer()
        try await waitForFinish(model)
        progress.cancel()
        try require(model.page == .success && model.verifiedCount == 2, "Resuming must reach Success without an existing-file collision")
        try require(observedLiveVerifiedCount == 2, "The live verified count must advance beyond the old partial receipt during retry")
        let resumedInode = try FileManager.default.attributesOfItem(atPath: firstCopy.path)[.systemFileNumber] as? NSNumber
        try require(initialInode == resumedInode, "Retry must reuse the first verified copy instead of replacing it")
        try verifyCopies(sources: sources, destination: destination, model: model)
        try archiveReceipt(model, label: "partial-resume-success")
    }

    private func makeModel() -> AppModel {
        let model = AppModel()
        models.append(model)
        return model
    }

    private func prepareTransfer(_ name: String, sizes: [Int]) async throws -> (AppModel, [URL], URL) {
        guard let externalFixture else { throw FlowCheckFailure("External fixture is not prepared") }
        let sourceFolder = externalFixture.appendingPathComponent(name, isDirectory: true)
        let destination = internalFixture.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var sources: [URL] = []
        for (index, size) in sizes.enumerated() {
            let file = sourceFolder.appendingPathComponent("flow-\(index + 1).pkg")
            try makeFile(file, bytes: size, seed: UInt8(index + 31))
            sources.append(file)
        }
        let model = makeModel()
        model.changeDirection(.toMac)
        model.continueSetup()
        model.addFiles(sources)
        try require(model.files.count == sizes.count && model.page == .files, "Drive source selection failed: \(model.errorMessage ?? "no details")")
        model.continueSetup()
        model.selectDestination(destination)
        try require(model.destination == destination && model.isBenchmarking && !model.canContinue, "Destination must be selected and benchmark must gate Continue")
        try await waitUntil("destination benchmark", model: model) { !model.isBenchmarking }
        try require(model.benchmarkError == nil && model.benchmark != nil, "Destination benchmark must complete: \(model.benchmarkError ?? "no result")")
        try require((model.benchmark?.readBytesPerSecond ?? 0) > 0 && (model.benchmark?.writeBytesPerSecond ?? 0) > 0, "Benchmark must return measured read and write rates")
        model.continueSetup()
        try require(model.page == .review && model.disposition == .keep, "Fixture must reach Review while preserving originals")
        return (model, sources, destination)
    }

    private func waitForFinish(_ model: AppModel) async throws {
        try await waitUntil("transfer completion", model: model) { !model.isTransferring }
    }

    private func waitUntil(_ description: String, model: AppModel, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else { throw FlowCheckFailure("Timed out waiting for \(description), page \(model.page), \(model.errorMessage ?? model.statusMessage)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeFile(_ url: URL, bytes: Int, seed: UInt8) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw FlowCheckFailure("Could not create owned fixture file") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 * 31) &+ seed })
        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
        try handle.synchronize()
    }

    private func verifyCopies(sources: [URL], destination: URL, model: AppModel) throws {
        try require(model.lastReceipt?.files.count == sources.count, "Success receipt must contain the full batch")
        for source in sources {
            let copied = destination.appendingPathComponent(source.lastPathComponent)
            let sourceDigest = SHA256.hash(data: try Data(contentsOf: source))
            let destinationDigest = SHA256.hash(data: try Data(contentsOf: copied))
            try require(sourceDigest == destinationDigest, "Test-owned destination data must match its source")
        }
        try require(model.lastReceipt?.files.allSatisfy { !$0.originalTrashed } == true, "Integration fixtures must keep all originals")
    }

    private func archiveReceipt(_ model: AppModel, label: String) throws {
        guard let url = model.receiptURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard url.deletingLastPathComponent().standardizedFileURL == model.receiptsFolder.standardizedFileURL,
              url.lastPathComponent.hasPrefix("Transfer-"), url.pathExtension == "json",
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]], !files.isEmpty,
              files.allSatisfy({ file in
                  guard let source = file["sourcePath"] as? String, let destination = file["destinationPath"] as? String else { return false }
                  return isOwnedPath(source) && isOwnedPath(destination)
              }) else { throw FlowCheckFailure("Refused to archive a receipt without exclusive fixture ownership") }
        try FileManager.default.createDirectory(at: receiptsDirectory, withIntermediateDirectories: true)
        let archived = receiptsDirectory.appendingPathComponent("\(label)-\(url.lastPathComponent)")
        try data.write(to: archived, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: url)
    }

    private func isOwnedPath(_ path: String) -> Bool {
        path.hasPrefix(internalFixture.path + "/") || (externalFixture.map { path.hasPrefix($0.path + "/") } ?? false)
    }

    func cleanUp() async {
        for model in models {
            await withCheckedContinuation { continuation in
                model.stopBeforeQuitting { continuation.resume() }
            }
            do { try archiveReceipt(model, label: "cleanup") }
            catch { failures += 1; print("FAIL receipt cleanup: \(error)") }
        }
        do {
            if let externalFixture, let externalVolume {
                try FileManager.default.removeItem(at: externalFixture)
                let sidecar = externalVolume.appendingPathComponent("._" + externalName)
                if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
            }
            if FileManager.default.fileExists(atPath: internalFixture.path) { try FileManager.default.removeItem(at: internalFixture) }
        } catch { failures += 1; print("FAIL owned fixture cleanup: \(error)") }
    }
}
