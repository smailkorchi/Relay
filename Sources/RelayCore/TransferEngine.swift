import Foundation
import CryptoKit
import Darwin

public struct DestinationIdentity: Equatable, Sendable {
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let filesystem: [Int32]
    public init(folder: URL) throws { self = try PinnedFolder(folder).identity }
    fileprivate init(device: dev_t, inode: ino_t, filesystem: [Int32]) {
        self.device = device; self.inode = inode; self.filesystem = filesystem
    }
}

public struct TransferRecovery: Sendable {
    fileprivate let sources: [SourceFile]
    fileprivate let destinationPath: String
    fileprivate let destinationIdentity: DestinationIdentity
    fileprivate let volumeUUID: String?
    fileprivate let relativeDestinationPath: String?
    fileprivate let disposition: SourceDisposition
    fileprivate let files: [VerifiedFileReceipt]
    fileprivate let publishedIdentities: [FileIdentity]
    fileprivate let incompleteArtifacts: [OwnedArtifact]
    fileprivate let hasUnidentifiedArtifact: Bool
    fileprivate let receiptID: UUID
    fileprivate let startedAt: Date

    /// Run on a background queue for an explicit retry; a changed destination requires user reselection.
    public func rebound(to folder: URL, expectedDestination: DestinationIdentity,
                        forceVerification: Bool = false, control: TransferControl,
                        progress: @escaping @Sendable (TransferEvent) -> Void) throws -> TransferRecovery {
        try TransferEngine.rebind(self, to: folder, expectedDestination: expectedDestination,
                                  forceVerification: forceVerification, control: control, progress: progress)
    }
}

public struct TransferRunFailure: LocalizedError, Sendable {
    public let receipt: TransferReceipt
    public let isCancellation: Bool
    public let isRetryable: Bool
    public let recovery: TransferRecovery?
    public let message: String
    public var errorDescription: String? { message }
}

// Internal fault points exercise retry boundaries without making real storage fail.
enum TransferFaultPoint: Sendable {
    case beforeCopy(fileIndex: Int, attempt: Int)
    case afterWrite(fileIndex: Int, attempt: Int, bytesWritten: Int64)
    case beforeTrash(fileIndex: Int)
    case beforeIncompleteCleanup(fileIndex: Int)
}

fileprivate struct OwnedArtifact: Sendable {
    let name: String
    let identity: FileIdentity
}

public enum TransferEngine {
    public static func run(_ request: TransferRequest, recovery: TransferRecovery? = nil,
                           control: TransferControl,
                           progress: @escaping @Sendable (TransferEvent) -> Void) throws -> TransferReceipt {
        try execute(request, recovery: recovery, control: control, progress: progress, fault: nil)
    }

    static func runForTesting(_ request: TransferRequest, recovery: TransferRecovery? = nil,
                              control: TransferControl,
                              progress: @escaping @Sendable (TransferEvent) -> Void = { _ in },
                              fault: @escaping @Sendable (TransferFaultPoint) throws -> Void) throws -> TransferReceipt {
        try execute(request, recovery: recovery, control: control, progress: progress, fault: fault)
    }

    private static func execute(_ request: TransferRequest, recovery: TransferRecovery?, control: TransferControl,
                                progress: @escaping @Sendable (TransferEvent) -> Void,
                                fault: (@Sendable (TransferFaultPoint) throws -> Void)?) throws -> TransferReceipt {
        let startedAt = recovery?.startedAt ?? Date()
        let receiptID = recovery?.receiptID ?? UUID()
        var files = recovery?.files ?? []
        var publishedIdentities = recovery?.publishedIdentities ?? []
        var incompleteArtifacts = recovery?.incompleteArtifacts ?? []
        var hasUnidentifiedArtifact = recovery?.hasUnidentifiedArtifact ?? false
        var preparedSources: [SourceFile] = []
        var preparedFolder: PinnedFolder?
        var total: Int64 = 0
        var completed: Int64 = files.reduce(0) { $0 + $1.byteCount * 2 }
        var phase = TransferPhase.preparing
        func report(_ message: String) {
            progress(TransferEvent(phase: phase, fileCount: request.sources.count,
                                   completedWorkBytes: completed, totalWorkBytes: total * 2,
                                   verifiedFileCount: files.count, message: message))
        }
        do {
            try control.checkCancellation()
            report(recovery == nil ? "Checking files and destination" : "Checking previously verified copies before retrying")
            let folder = try PinnedFolder(request.destination)
            if let expected = request.expectedDestination, expected != folder.identity {
                throw TransferFailure("The selected destination changed. Select the destination again before transferring.")
            }
            let sources: [SourceFile]
            if let recovery {
                sources = try validateRecovery(recovery, request: request, folder: folder)
            } else {
                sources = try preflight(request.sources, folder: folder)
            }
            preparedSources = sources
            preparedFolder = folder
            for source in sources {
                let sum = total.addingReportingOverflow(source.identity.size)
                guard !sum.overflow, sum.partialValue <= Int64.max / 2 else {
                    throw TransferFailure("This batch is too large.")
                }
                total = sum.partialValue
            }
            let remaining = sources.dropFirst(files.count).reduce(Int64(0)) { $0 + $1.identity.size }
            try folder.requireSpace(remaining)
            if files.count < sources.count { try folder.preparePublication() }
            if !files.isEmpty { report("Reusing \(files.count) unchanged, previously verified copies") }
            for index in files.count..<sources.count {
                let source = sources[index]
                var attempt = 1
                while true {
                    try control.checkCancellation()
                    phase = .copying
                    do {
                        try fault?(.beforeCopy(fileIndex: index + 1, attempt: attempt))
                        let copied = try copy(source, to: folder, index: index + 1, count: sources.count,
                                              completed: completed, total: total * 2, verified: files.count,
                                              attempt: attempt, control: control, progress: progress, fault: fault,
                                              leftover: { artifact in
                            if let artifact { incompleteArtifacts.append(artifact) }
                            else { hasUnidentifiedArtifact = true }
                        })
                        files.append(copied.receipt)
                        publishedIdentities.append(copied.identity)
                        completed += source.identity.size * 2
                        // Record the verified copy before directory flush, so a flush failure can resume safely.
                        try folder.flushDirectory()
                        break
                    } catch {
                        guard files.count == index, attempt < 3, isTransient(error),
                              incompleteArtifacts.isEmpty, !hasUnidentifiedArtifact else { throw error }
                        try control.checkCancellation()
                        try folder.check()
                        try source.validate()
                        for verifiedIndex in files.indices {
                            try folder.requireUnchanged(sources[verifiedIndex].url.lastPathComponent,
                                                        identity: publishedIdentities[verifiedIndex])
                        }
                        phase = .preparing
                        report("Retrying \(source.url.lastPathComponent) after a temporary I/O error (attempt \(attempt + 1) of 3)")
                        try waitForRetry(attempt == 1 ? 0.25 : 0.75, control: control)
                        try folder.check()
                        try source.validate()
                        attempt += 1
                    }
                }
            }
            try control.checkCancellation()
            try folder.flushDirectory()
            for index in sources.indices {
                try folder.requireUnchanged(sources[index].url.lastPathComponent, identity: publishedIdentities[index])
            }
            if request.disposition == .trashAfterVerification {
                phase = .movingOriginals
                report("All files verified. Checking originals before moving them to Trash.")
                // An earlier source can change during a later copy. Already trashed sources are never reopened.
                for index in sources.indices where !files[index].originalTrashed { try sources[index].validate() }
                for index in sources.indices where !files[index].originalTrashed {
                    try control.checkCancellation()
                    try folder.check()
                    try folder.requireUnchanged(sources[index].url.lastPathComponent, identity: publishedIdentities[index])
                    try sources[index].validate()
                    try fault?(.beforeTrash(fileIndex: index + 1))
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: sources[index].url, resultingItemURL: &trashed)
                    files[index].originalTrashed = true
                    files[index].trashPath = trashed?.path
                    report("Moved \(files.filter(\.originalTrashed).count) of \(sources.count) originals to Trash")
                }
            }
            for index in sources.indices {
                try folder.requireUnchanged(sources[index].url.lastPathComponent, identity: publishedIdentities[index])
            }
            phase = .complete
            report(request.disposition == .keep ? "All copies verified. Originals kept." : "All copies verified. Originals moved to Trash.")
            return TransferReceipt(id: receiptID, startedAt: startedAt, disposition: request.disposition, files: files)
        } catch {
            let wasCleaningUp = phase == .movingOriginals
            let trashedCount = files.filter(\.originalTrashed).count
            var message: String
            if trashedCount > 0 {
                message = "Transfer stopped. \(trashedCount) originals were already moved to Trash; remaining originals were kept. The receipt records completed transfers and Trash locations. \(error.localizedDescription)"
            } else {
                message = "\(error is CancellationError ? "Transfer cancelled." : error.localizedDescription) Originals were kept."
            }
            if hasUnidentifiedArtifact {
                message += " Relay could not confirm ownership of an incomplete file. Choose a new empty destination folder; existing files will be preserved."
            } else if !incompleteArtifacts.isEmpty {
                message += " An incomplete copy remains. Reselect this destination to reclaim Relay's unchanged partial before retrying."
            }
            let nextRecovery: TransferRecovery?
            if let folder = preparedFolder {
                nextRecovery = TransferRecovery(sources: preparedSources, destinationPath: folder.url.path,
                                                destinationIdentity: folder.identity, volumeUUID: folder.volumeUUID,
                                                relativeDestinationPath: folder.relativePath, disposition: request.disposition,
                                                files: files, publishedIdentities: publishedIdentities,
                                                incompleteArtifacts: incompleteArtifacts, hasUnidentifiedArtifact: hasUnidentifiedArtifact,
                                                receiptID: receiptID, startedAt: startedAt)
            } else {
                nextRecovery = recovery
            }
            let cleanupCanRetry = wasCleaningUp && ((error as? TransferFailure)?.code != nil || !(error is TransferFailure))
            let retryable = !hasUnidentifiedArtifact && (error is CancellationError || isTransient(error) || isOffline(error) || isManuallyRepairable(error) || cleanupCanRetry)
            phase = error is CancellationError ? .cancelled : .failed
            report(message)
            throw TransferRunFailure(receipt: TransferReceipt(id: receiptID, startedAt: startedAt,
                                                              disposition: recovery?.disposition ?? request.disposition, files: files),
                                     isCancellation: error is CancellationError, isRetryable: retryable,
                                     recovery: nextRecovery, message: message)
        }
    }

    fileprivate static func rebind(_ recovery: TransferRecovery, to url: URL,
                                   expectedDestination: DestinationIdentity, forceVerification: Bool, control: TransferControl,
                                   progress: @escaping @Sendable (TransferEvent) -> Void) throws -> TransferRecovery {
        do {
            try control.checkCancellation()
            let folder = try PinnedFolder(url)
            guard folder.identity == expectedDestination else {
                throw TransferFailure("The reselected destination changed. Select it again before retrying.")
            }
            guard let uuid = recovery.volumeUUID, let relative = recovery.relativeDestinationPath,
                  folder.volumeUUID == uuid, folder.relativePath == relative else {
                throw TransferFailure("Choose the same drive and folder used by this transfer. Relay cannot adopt copies on another destination.")
            }
            guard !recovery.hasUnidentifiedArtifact else {
                throw TransferFailure("Relay could not identify an incomplete file after the interruption. Choose a new empty destination folder; no existing file will be replaced.")
            }
            var sources = recovery.sources
            for index in sources.indices where index >= recovery.files.count || !recovery.files[index].originalTrashed {
                let prior = sources[index]
                let current = try SourceFile(prior.url)
                if prior.identity == current.identity {
                    guard prior.volumeUUID == current.volumeUUID, prior.relativePath == current.relativePath else {
                        throw TransferFailure("The source volume changed: \(prior.url.lastPathComponent).")
                    }
                    if forceVerification && index < recovery.files.count {
                        let descriptor = try current.openValidated()
                        defer { Darwin.close(descriptor) }
                        try verifyReconnectedSource(descriptor, source: current, receipt: recovery.files[index],
                                                    index: index + 1, count: sources.count,
                                                    control: control, progress: progress)
                    }
                    continue
                }
                guard let sourceUUID = prior.volumeUUID, current.volumeUUID == sourceUUID,
                      let relative = prior.relativePath, current.relativePath == relative,
                      prior.identity.device != current.identity.device,
                      prior.identity.matchesIgnoringDevice(current.identity) else {
                    throw TransferFailure("The original changed: \(prior.url.lastPathComponent). It cannot be reused for this retry.")
                }
                if index < recovery.files.count {
                    let descriptor = try current.openValidated()
                    defer { Darwin.close(descriptor) }
                    try verifyReconnectedSource(descriptor, source: current, receipt: recovery.files[index],
                                                index: index + 1, count: sources.count,
                                                control: control, progress: progress)
                }
                sources[index] = current
            }
            if !forceVerification, folder.identity == recovery.destinationIdentity, folder.url.path == recovery.destinationPath {
                for index in recovery.files.indices {
                    try folder.requireUnchanged(recovery.sources[index].url.lastPathComponent,
                                                identity: recovery.publishedIdentities[index])
                }
                try reclaimArtifacts(recovery, folder: folder, control: control)
                return TransferRecovery(sources: sources, destinationPath: recovery.destinationPath,
                                        destinationIdentity: recovery.destinationIdentity, volumeUUID: recovery.volumeUUID,
                                        relativeDestinationPath: recovery.relativeDestinationPath, disposition: recovery.disposition,
                                        files: recovery.files, publishedIdentities: recovery.publishedIdentities,
                                        incompleteArtifacts: [], hasUnidentifiedArtifact: false,
                                        receiptID: recovery.receiptID, startedAt: recovery.startedAt)
            }
            let total = recovery.files.reduce(Int64(0)) { $0 + $1.byteCount }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileIO.bufferSize, alignment: 4096)
            defer { buffer.deallocate() }
            var identities: [FileIdentity] = []
            var files = recovery.files
            var completed: Int64 = 0
            for index in files.indices {
                try control.checkCancellation()
                let name = recovery.sources[index].url.lastPathComponent
                let descriptor = try folder.openRead(name)
                defer { Darwin.close(descriptor) }
                try FileIO.uncached(descriptor)
                let identity = try FileIdentity(descriptor: descriptor)
                var hash = SHA256()
                var bytes: Int64 = 0
                let started = ProcessInfo.processInfo.systemUptime
                var lastReport = started
                func report() {
                    let elapsed = max(ProcessInfo.processInfo.systemUptime - started, 0.001)
                    progress(TransferEvent(phase: .verifying, fileIndex: index + 1,
                                           fileCount: recovery.sources.count, filename: name,
                                           fileBytesDone: bytes, fileBytesTotal: files[index].byteCount,
                                           completedWorkBytes: completed + bytes, totalWorkBytes: total,
                                           readBytesPerSecond: Double(bytes) / elapsed,
                                           verifiedFileCount: index,
                                           message: "Checking previously verified copies after reconnecting the drive"))
                }
                report()
                while true {
                    try control.checkCancellation()
                    try folder.check()
                    let amount = try FileIO.read(descriptor, into: buffer, count: FileIO.bufferSize)
                    if amount == 0 { break }
                    bytes += Int64(amount)
                    guard bytes <= files[index].byteCount else {
                        throw TransferFailure("A saved copy changed after reconnecting: \(name). Originals will be kept.")
                    }
                    hash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
                    if ProcessInfo.processInfo.systemUptime - lastReport >= 0.2 {
                        report(); lastReport = ProcessInfo.processInfo.systemUptime
                    }
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard bytes == files[index].byteCount, digest == files[index].sha256,
                      identity == (try FileIdentity(descriptor: descriptor)) else {
                    throw TransferFailure("A saved copy failed verification after reconnecting: \(name). Originals will be kept.")
                }
                try folder.requireUnchanged(name, identity: identity)
                identities.append(identity)
                files[index].destinationPath = folder.url.appendingPathComponent(name).path
                report()
                completed += bytes
            }
            try reclaimArtifacts(recovery, folder: folder, control: control)
            for index in recovery.files.count..<recovery.sources.count {
                guard try !folder.exists(recovery.sources[index].url.lastPathComponent) else {
                    throw TransferFailure("An unfinished file now exists in the destination. Relay will not overwrite it.")
                }
            }
            try control.checkCancellation()
            try folder.check()
            return TransferRecovery(sources: sources, destinationPath: folder.url.path,
                                    destinationIdentity: folder.identity, volumeUUID: folder.volumeUUID,
                                    relativeDestinationPath: folder.relativePath, disposition: recovery.disposition,
                                    files: files, publishedIdentities: identities,
                                    incompleteArtifacts: [], hasUnidentifiedArtifact: false,
                                    receiptID: recovery.receiptID, startedAt: recovery.startedAt)
        } catch {
            throw TransferRunFailure(receipt: TransferReceipt(id: recovery.receiptID, startedAt: recovery.startedAt,
                                                              disposition: recovery.disposition, files: recovery.files),
                                     isCancellation: error is CancellationError,
                                     isRetryable: error is CancellationError || isTransient(error) || isOffline(error) || isManuallyRepairable(error),
                                     recovery: recovery, message: error.localizedDescription)
        }
    }

    private static func reclaimArtifacts(_ recovery: TransferRecovery, folder: PinnedFolder,
                                         control: TransferControl) throws {
        // Validate the complete set before removing any known partial. A changed entry is never reclaimed.
        for artifact in recovery.incompleteArtifacts {
            try control.checkCancellation()
            try folder.check()
            guard try folder.exists(artifact.name) else { continue }
            let descriptor = try folder.openRead(artifact.name)
            defer { Darwin.close(descriptor) }
            let current = try FileIdentity(descriptor: descriptor)
            guard artifact.identity.matchesIgnoringDevice(current) else {
                throw TransferFailure("The incomplete file changed or was replaced. Relay will preserve it. Choose a new empty destination folder.")
            }
            try folder.requireUnchanged(artifact.name, identity: current)
        }
        for artifact in recovery.incompleteArtifacts {
            try control.checkCancellation()
            guard try folder.exists(artifact.name) else { continue }
            try folder.reclaim(artifact)
        }
        if !recovery.incompleteArtifacts.isEmpty { try folder.flushDirectory() }
    }

    private static func verifyReconnectedSource(_ descriptor: Int32, source: SourceFile, receipt: VerifiedFileReceipt,
                                                index: Int, count: Int, control: TransferControl,
                                                progress: @escaping @Sendable (TransferEvent) -> Void) throws {
        try FileIO.uncached(descriptor)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileIO.bufferSize, alignment: 4096)
        defer { buffer.deallocate() }
        var hash = SHA256()
        var bytes: Int64 = 0
        let started = ProcessInfo.processInfo.systemUptime
        var lastReport = started
        func report() {
            progress(TransferEvent(phase: .verifying, fileIndex: index, fileCount: count,
                                   filename: source.url.lastPathComponent, fileBytesDone: bytes,
                                   fileBytesTotal: receipt.byteCount, completedWorkBytes: bytes,
                                   totalWorkBytes: receipt.byteCount,
                                   readBytesPerSecond: Double(bytes) / max(ProcessInfo.processInfo.systemUptime - started, 0.001),
                                   message: "Checking a previously verified source after reconnecting its drive"))
        }
        report()
        while true {
            try control.checkCancellation()
            let amount = try FileIO.read(descriptor, into: buffer, count: FileIO.bufferSize)
            if amount == 0 { break }
            bytes += Int64(amount)
            guard bytes <= receipt.byteCount else { throw TransferFailure("The reconnected source changed during checking.") }
            hash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
            if ProcessInfo.processInfo.systemUptime - lastReport >= 0.2 {
                report(); lastReport = ProcessInfo.processInfo.systemUptime
            }
        }
        try source.validate(descriptor: descriptor)
        guard bytes == receipt.byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else {
            throw TransferFailure("The reconnected source failed verification: \(source.url.lastPathComponent). Originals will be kept.")
        }
        report()
    }

    private static func validateRecovery(_ recovery: TransferRecovery, request: TransferRequest,
                                         folder: PinnedFolder) throws -> [SourceFile] {
        guard recovery.destinationPath == folder.url.path, recovery.destinationIdentity == folder.identity,
              recovery.disposition == request.disposition,
              recovery.sources.map({ $0.url.path }) == request.sources.map({ $0.standardizedFileURL.path }) else {
            throw TransferFailure("This retry no longer matches the original files, destination, or cleanup choice. Start a new transfer.")
        }
        guard recovery.incompleteArtifacts.isEmpty, !recovery.hasUnidentifiedArtifact else {
            throw TransferFailure("Reselect the destination to safely check Relay's incomplete copy before retrying.", code: ENXIO)
        }
        for index in recovery.sources.indices {
            let source = recovery.sources[index]
            if index < recovery.files.count {
                try folder.requireUnchanged(source.url.lastPathComponent, identity: recovery.publishedIdentities[index])
                if !recovery.files[index].originalTrashed { try source.validate() }
            } else {
                try source.validate()
                guard try !folder.exists(source.url.lastPathComponent) else {
                    throw TransferFailure("\(source.url.lastPathComponent) now exists in the destination. Relay will not overwrite it.")
                }
            }
        }
        return recovery.sources
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? TransferFailure)?.code else { return false }
        return [EIO, EAGAIN, ETIMEDOUT, EBUSY].contains(code)
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let code = (error as? TransferFailure)?.code else { return false }
        return [ENXIO, ENODEV, ESTALE].contains(code)
    }

    private static func isManuallyRepairable(_ error: Error) -> Bool {
        guard let code = (error as? TransferFailure)?.code else { return false }
        return [ENOSPC, EDQUOT, EACCES, EPERM].contains(code)
    }

    private static func waitForRetry(_ seconds: TimeInterval, control: TransferControl) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            try control.checkCancellation()
            let remaining = end - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.025))
        }
    }

    private static func preflight(_ urls: [URL], folder: PinnedFolder) throws -> [SourceFile] {
        guard !urls.isEmpty else { throw TransferFailure("Add at least one file.") }
        var names = Set<String>()
        var identities = Set<String>()
        var result: [SourceFile] = []
        for url in urls {
            let source = try SourceFile(url)
            let name = source.url.lastPathComponent.precomposedStringWithCanonicalMapping
            let comparison = folder.caseSensitive ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(comparison).inserted else {
                throw TransferFailure("Two files have the same destination name: \(name). Rename one before transferring.")
            }
            guard identities.insert("\(source.identity.device):\(source.identity.inode)").inserted else {
                throw TransferFailure("The same source file was added more than once: \(name).")
            }
            guard try !folder.exists(name) else {
                throw TransferFailure("\(name) already exists in the destination. Relay never overwrites existing files.")
            }
            result.append(source)
        }
        try folder.check()
        return result
    }

    private static func copy(_ source: SourceFile, to folder: PinnedFolder, index: Int, count: Int,
                             completed: Int64, total: Int64, verified: Int, attempt: Int, control: TransferControl,
                             progress: @escaping @Sendable (TransferEvent) -> Void,
                             fault: (@Sendable (TransferFaultPoint) throws -> Void)?,
                             leftover: (OwnedArtifact?) -> Void) throws -> PublishedCopy {
        try folder.check()
        let sourceFD = try source.openValidated()
        defer { Darwin.close(sourceFD) }
        try FileIO.uncached(sourceFD)
        // ExFAT cannot atomically rename without replacing. Its final name is created O_EXCL once,
        // stays incomplete while copying, and is retained only after readback verification succeeds.
        let workingName = folder.supportsExclusiveRename ? ".relay-\(UUID().uuidString).partial" : source.url.lastPathComponent
        var destinationFD = try folder.createExclusive(workingName)
        var createdIdentity: FileIdentity?
        var completedCopy = false
        defer {
            var failedIdentity: FileIdentity?
            if !completedCopy {
                if destinationFD >= 0 { failedIdentity = try? FileIdentity(descriptor: destinationFD) }
                else if let reopened = try? folder.openRead(workingName) {
                    failedIdentity = try? FileIdentity(descriptor: reopened)
                    Darwin.close(reopened)
                }
            }
            if destinationFD >= 0 { Darwin.close(destinationFD) }
            if !completedCopy, let createdIdentity {
                let removed: Bool
                do {
                    try fault?(.beforeIncompleteCleanup(fileIndex: index))
                    removed = folder.removeOwned(workingName, identity: createdIdentity)
                } catch { removed = false }
                if !removed {
                    if let failedIdentity, failedIdentity.device == createdIdentity.device,
                       failedIdentity.inode == createdIdentity.inode {
                        leftover(OwnedArtifact(name: workingName, identity: failedIdentity))
                    } else { leftover(nil) }
                }
            } else if !completedCopy {
                leftover(nil)
            }
        }
        createdIdentity = try FileIdentity(descriptor: destinationFD)
        try FileIO.uncached(destinationFD)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileIO.bufferSize, alignment: 4096)
        defer { buffer.deallocate() }
        var lastReport = ProcessInfo.processInfo.systemUptime
        var phaseStart = lastReport
        var bytes: Int64 = 0
        var sourceHash = SHA256()
        func report(_ phase: TransferPhase, force: Bool = false, message: String = "") {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastReport >= 0.2 else { return }
            lastReport = now
            let rate = Double(bytes) / max(now - phaseStart, 0.001)
            let work = completed + (phase == .verifying ? source.identity.size : 0) + bytes
            progress(TransferEvent(phase: phase, fileIndex: index, fileCount: count,
                                   filename: source.url.lastPathComponent,
                                   fileBytesDone: bytes, fileBytesTotal: source.identity.size,
                                   completedWorkBytes: min(work, total), totalWorkBytes: total,
                                   readBytesPerSecond: phase == .copying || phase == .verifying ? rate : 0,
                                   writeBytesPerSecond: phase == .copying ? rate : 0,
                                   verifiedFileCount: verified, message: message))
        }
        report(.copying, force: true)
        while true {
            try control.checkCancellation()
            try folder.check()
            let amount = try FileIO.read(sourceFD, into: buffer, count: FileIO.bufferSize)
            if amount == 0 { break }
            guard bytes <= source.identity.size - Int64(amount) else {
                throw TransferFailure("\(source.url.lastPathComponent) changed during the transfer. Its original was kept.")
            }
            sourceHash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
            try FileIO.writeAll(destinationFD, from: buffer, count: amount)
            bytes += Int64(amount)
            try fault?(.afterWrite(fileIndex: index, attempt: attempt, bytesWritten: bytes))
            report(.copying)
        }
        guard bytes == source.identity.size else { throw TransferFailure("The source size changed: \(source.url.lastPathComponent).") }
        try source.validate(descriptor: sourceFD)
        report(.flushing, force: true)
        try FileIO.flush(destinationFD)
        let copiedIdentity = try FileIdentity(descriptor: destinationFD)
        let writtenFD = destinationFD
        destinationFD = -1
        try FileIO.closeChecked(writtenFD)
        try control.checkCancellation()
        try folder.check()

        bytes = 0
        phaseStart = ProcessInfo.processInfo.systemUptime
        report(.verifying, force: true, message: "Reading the saved file and comparing SHA-256")
        destinationFD = try folder.openRead(workingName)
        try FileIO.uncached(destinationFD)
        let beforeRead = try FileIdentity(descriptor: destinationFD)
        guard beforeRead == copiedIdentity else {
            throw TransferFailure("The saved file changed before verification. Its original was kept.")
        }
        var destinationHash = SHA256()
        while true {
            try control.checkCancellation()
            try folder.check()
            let amount = try FileIO.read(destinationFD, into: buffer, count: FileIO.bufferSize)
            if amount == 0 { break }
            bytes += Int64(amount)
            guard bytes <= source.identity.size else { throw TransferFailure("The saved file changed during verification.") }
            destinationHash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
            report(.verifying)
        }
        let digest = sourceHash.finalize()
        guard bytes == source.identity.size, digest == destinationHash.finalize(),
              beforeRead == (try FileIdentity(descriptor: destinationFD)) else {
            throw TransferFailure("Verification failed for \(source.url.lastPathComponent). Its original was kept. Try another cable or port.")
        }
        let verifiedFD = destinationFD
        destinationFD = -1
        try FileIO.closeChecked(verifiedFD)
        try control.checkCancellation()
        try source.validate(descriptor: sourceFD)
        let publishedIdentity: FileIdentity
        if folder.supportsExclusiveRename {
            publishedIdentity = try folder.publish(workingName, as: source.url.lastPathComponent, identity: beforeRead)
        } else {
            try folder.requireUnchanged(workingName, identity: beforeRead)
            publishedIdentity = beforeRead
        }
        completedCopy = true
        progress(TransferEvent(phase: .verifying, fileIndex: index, fileCount: count,
                               filename: source.url.lastPathComponent, fileBytesDone: bytes,
                               fileBytesTotal: source.identity.size,
                               completedWorkBytes: completed + bytes * 2, totalWorkBytes: total,
                               readBytesPerSecond: Double(bytes) / max(ProcessInfo.processInfo.systemUptime - phaseStart, 0.001),
                               verifiedFileCount: verified + 1, message: "SHA-256 matched"))
        let receipt = VerifiedFileReceipt(sourcePath: source.url.path,
                                   destinationPath: folder.url.appendingPathComponent(source.url.lastPathComponent).path,
                                   byteCount: source.identity.size,
                                   sha256: digest.map { String(format: "%02x", $0) }.joined())
        return PublishedCopy(receipt: receipt, identity: publishedIdentity)
    }
}

private struct PublishedCopy {
    let receipt: VerifiedFileReceipt
    let identity: FileIdentity
}

struct TransferFailure: LocalizedError {
    let message: String
    let code: Int32?
    init(_ message: String, code: Int32? = nil) { self.message = message; self.code = code }
    var errorDescription: String? { message }
}

struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FileIO.error("Read file identity") }
        self.init(info)
    }
    init(path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw FileIO.error("Read file identity") }
        self.init(info)
    }
    func matchesIgnoringDevice(_ other: FileIdentity) -> Bool {
        inode == other.inode && size == other.size && mode == other.mode &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos &&
        changedSeconds == other.changedSeconds && changedNanos == other.changedNanos
    }
}

struct SourceFile: Sendable {
    let url: URL
    let identity: FileIdentity
    let volumeUUID: String?
    let relativePath: String?
    private let volumeRootPath: String?
    init(_ url: URL) throws {
        guard url.isFileURL else { throw TransferFailure("Only local files can be transferred.") }
        self.url = url.standardizedFileURL
        identity = try FileIdentity(path: self.url.path)
        guard identity.mode & S_IFMT == S_IFREG else {
            throw TransferFailure("Add regular files only. Folders and symbolic links are not supported: \(url.lastPathComponent).")
        }
        let location = try VolumeLocation(self.url)
        volumeUUID = location.uuid; relativePath = location.relativePath
        volumeRootPath = location.rootPath
    }
    func openValidated() throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = FileIO.error("Open \(url.lastPathComponent)")
            try requireVolumePresent()
            throw error
        }
        do { try validate(descriptor: descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }
    func validate(descriptor: Int32? = nil) throws {
        try requireVolumePresent()
        guard identity == (try FileIdentity(path: url.path)),
              try descriptor.map({ try FileIdentity(descriptor: $0) == identity }) ?? true else {
            throw TransferFailure("The original changed: \(url.lastPathComponent). It will not be moved to Trash.")
        }
        let location = try VolumeLocation(url)
        guard volumeUUID == location.uuid, relativePath == location.relativePath else {
            throw TransferFailure("The source volume changed: \(url.lastPathComponent). Its original will be kept.")
        }
    }
    private func requireVolumePresent() throws {
        guard let volumeRootPath, let volumeUUID else { return }
        let current = try? VolumeLocation(URL(fileURLWithPath: volumeRootPath, isDirectory: true))
        guard current?.uuid == volumeUUID else {
            throw TransferFailure("The source drive is disconnected or changed. Reconnect the original drive before retrying.", code: ENXIO)
        }
    }
}

private struct VolumeLocation {
    let uuid: String?
    let relativePath: String?
    let rootPath: String?
    init(_ url: URL) throws {
        let freshURL = URL(fileURLWithPath: url.path)
        let resources = try freshURL.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        uuid = resources.volumeUUIDString
        rootPath = resources.volume?.standardizedFileURL.resolvingSymlinksInPath().path
        if let root = rootPath {
            if url.path == root { relativePath = "" }
            else if root == "/" { relativePath = String(url.path.dropFirst()) }
            else if url.path.hasPrefix(root + "/") { relativePath = String(url.path.dropFirst(root.count + 1)) }
            else { relativePath = nil }
        } else { relativePath = nil }
    }
}

// The open directory and its mount identity keep a disconnected drive from becoming an ordinary fallback folder.
final class PinnedFolder {
    let url: URL
    let descriptor: Int32
    let caseSensitive: Bool
    let identity: DestinationIdentity
    let volumeUUID: String?
    let relativePath: String?
    private(set) var supportsExclusiveRename = false
    private let canProbeExclusiveRename: Bool

    init(_ url: URL) throws {
        guard url.isFileURL else { throw TransferFailure("Choose a local destination folder.") }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FileIO.error("Open destination folder") }
        do {
            let identity = try FileIdentity(descriptor: descriptor)
            var fs = statfs()
            guard fstatfs(descriptor, &fs) == 0 else { throw FileIO.error("Identify destination volume") }
            guard fs.f_flags & UInt32(MNT_RDONLY) == 0 else { throw TransferFailure("The destination is read-only.") }
            self.identity = DestinationIdentity(device: identity.device, inode: identity.inode,
                                               filesystem: [fs.f_fsid.val.0, fs.f_fsid.val.1])
            self.descriptor = descriptor
            let resources = try URL(fileURLWithPath: self.url.path, isDirectory: true)
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey, .volumeUUIDStringKey, .volumeURLKey])
            caseSensitive = resources.volumeSupportsCaseSensitiveNames ?? false
            volumeUUID = resources.volumeUUIDString
            if let volume = resources.volume?.standardizedFileURL.resolvingSymlinksInPath().path {
                if self.url.path == volume { relativePath = "" }
                else if volume == "/" { relativePath = String(self.url.path.dropFirst()) }
                else if self.url.path.hasPrefix(volume + "/") { relativePath = String(self.url.path.dropFirst(volume.count + 1)) }
                else { relativePath = nil }
            } else { relativePath = nil }
            let filesystemType = withUnsafePointer(to: &fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            // The macOS ExFAT driver can accept zero-byte probes yet reject RENAME_EXCL for real files.
            // Only native filesystems with known support attempt atomic publication; others use O_EXCL data FDs.
            canProbeExclusiveRename = filesystemType == "apfs" || filesystemType == "hfs"
        } catch { Darwin.close(descriptor); throw error }
    }
    deinit { Darwin.close(descriptor) }
    func check() throws {
        let current = try FileIdentity(path: url.path)
        let opened = try FileIdentity(descriptor: descriptor)
        var fs = statfs()
        guard fstatfs(descriptor, &fs) == 0 else { throw FileIO.error("Check destination connection") }
        guard current.device == identity.device, current.inode == identity.inode,
              opened.device == identity.device, opened.inode == identity.inode,
              identity.filesystem == [fs.f_fsid.val.0, fs.f_fsid.val.1] else {
            throw TransferFailure("The destination was disconnected or changed. Reconnect it and start again.")
        }
    }
    func requireSpace(_ bytes: Int64) throws {
        try check()
        var fs = statfs()
        guard fstatfs(descriptor, &fs) == 0 else { throw FileIO.error("Read available space") }
        let available = UInt64(fs.f_bavail).multipliedReportingOverflow(by: UInt64(fs.f_bsize))
        guard available.overflow || available.partialValue >= UInt64(bytes) else {
            throw TransferFailure("The destination does not have enough free space for this batch.", code: ENOSPC)
        }
    }
    func preparePublication() throws {
        guard canProbeExclusiveRename else { supportsExclusiveRename = false; return }
        let first = ".relay-probe-\(UUID().uuidString)"
        let second = ".relay-probe-\(UUID().uuidString)"
        let from = try createExclusive(first)
        defer { Darwin.close(from); removeOwnedTemporary(first) }
        let to = try createExclusive(second)
        defer { Darwin.close(to); removeOwnedTemporary(second) }
        // Both names are ours. A supported exclusive rename must refuse the occupied second name.
        if renameatx_np(descriptor, first, descriptor, second, UInt32(RENAME_EXCL)) == 0 {
            supportsExclusiveRename = false
        } else if errno == EEXIST {
            guard unlinkat(descriptor, second, 0) == 0 else { throw FileIO.error("Remove publication probe") }
            if renameatx_np(descriptor, first, descriptor, second, UInt32(RENAME_EXCL)) == 0 {
                supportsExclusiveRename = true
            } else if errno == ENOTSUP || errno == EINVAL {
                supportsExclusiveRename = false
            } else {
                throw FileIO.error("Check safe file publication")
            }
        } else if errno == ENOTSUP || errno == EINVAL {
            supportsExclusiveRename = false
        } else {
            throw FileIO.error("Check safe file publication")
        }
    }
    func exists(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw FileIO.error("Check destination name")
    }
    func createExclusive(_ name: String) throws -> Int32 {
        try check()
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw FileIO.error("Create \(name)") }
        return file
    }
    func openRead(_ name: String) throws -> Int32 {
        try check()
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw FileIO.error("Reopen saved file") }
        return file
    }
    func removeOwnedTemporary(_ name: String) { _ = unlinkat(descriptor, name, 0) }
    func removeOwnedTemporaryChecked(_ name: String) throws {
        guard unlinkat(descriptor, name, 0) == 0 else { throw FileIO.error("Remove speed-test file") }
    }
    @discardableResult
    func removeOwned(_ name: String, identity expected: FileIdentity) -> Bool {
        guard let current = identity(of: name) else { return (try? exists(name)) == false }
        guard current.device == expected.device, current.inode == expected.inode else { return false }
        return unlinkat(descriptor, name, 0) == 0 || errno == ENOENT
    }
    fileprivate func reclaim(_ artifact: OwnedArtifact) throws {
        try check()
        guard let current = identity(of: artifact.name), artifact.identity.matchesIgnoringDevice(current) else {
            throw TransferFailure("The incomplete file changed or was replaced. Choose a new empty destination folder; Relay will preserve existing files.")
        }
        guard unlinkat(descriptor, artifact.name, 0) == 0 else { throw FileIO.error("Remove Relay's unchanged incomplete copy") }
    }
    func requireUnchanged(_ name: String, identity expected: FileIdentity) throws {
        try check()
        guard identity(of: name) == expected else {
            throw TransferFailure("The verified destination changed or disappeared: \(name). Remaining originals will be kept.")
        }
    }
    func publish(_ temporary: String, as name: String, identity verifiedIdentity: FileIdentity) throws -> FileIdentity {
        try check()
        guard identity(of: temporary) == verifiedIdentity else {
            throw TransferFailure("The verified file changed before it could be saved.")
        }
        guard renameatx_np(descriptor, temporary, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FileIO.error("Publish verified file without overwriting")
        }
        guard let final = identity(of: name), final.device == verifiedIdentity.device,
              final.inode == verifiedIdentity.inode, final.size == verifiedIdentity.size,
              final.modifiedSeconds == verifiedIdentity.modifiedSeconds, final.modifiedNanos == verifiedIdentity.modifiedNanos else {
            throw TransferFailure("The saved file changed while publishing \(name). Its original was kept.")
        }
        return final
    }
    func flushDirectory() throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            if errno == ENOTSUP || errno == EINVAL { break }
            throw FileIO.error("Save destination directory")
        }
    }
    private func identity(of name: String) -> FileIdentity? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return FileIdentity(info)
    }
}

enum FileIO {
    static let bufferSize = 8 * 1024 * 1024
    static func error(_ operation: String) -> TransferFailure {
        let code = errno
        return TransferFailure("\(operation): \(String(cString: strerror(code))) (\(code)).", code: code)
    }
    static func uncached(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_NOCACHE, 1) == 0 else { throw error("Disable file caching") }
    }
    static func read(_ descriptor: Int32, into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let amount = Darwin.read(descriptor, buffer, count)
            if amount >= 0 { return amount }
            if errno != EINTR { throw error("Read file") }
        }
    }
    static func writeAll(_ descriptor: Int32, from buffer: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let amount = Darwin.write(descriptor, buffer.advanced(by: written), count - written)
            if amount < 0 {
                if errno == EINTR { continue }
                throw error("Write file")
            }
            guard amount > 0 else { throw TransferFailure("The destination stopped accepting data.") }
            written += amount
        }
    }
    static func flush(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 { if errno != EINTR { throw error("Flush saved file") } }
        while fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            if errno == ENOTSUP || errno == EINVAL { break }
            throw error("Flush drive write cache")
        }
    }
    static func closeChecked(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else { throw error("Close saved file") }
    }
}
