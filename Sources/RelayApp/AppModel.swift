import AppKit
import Combine
import Foundation
import RelayCore

struct QueuedFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
}

struct DriveVolume: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let availableBytes: Int64
    let isInternal: Bool
    let isReadOnly: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var direction: TransferDirection = .toDrive
    @Published var disposition: SourceDisposition = .keep
    @Published var files: [QueuedFile] = []
    @Published var destination: URL?
    @Published var volumes: [DriveVolume] = []
    @Published var event: TransferEvent?
    @Published var benchmark: BenchmarkResult?
    @Published var isBenchmarking = false
    @Published var benchmarkStatus = "Choose a destination to measure its speed."
    @Published var benchmarkError: String?
    @Published var isTransferring = false
    @Published var statusMessage = "Ready when you are."
    @Published var errorMessage: String?
    @Published var receiptURL: URL?
    @Published var completed = false
    @Published var page: RelayPage = .direction
    @Published var navigationDirection = 1
    @Published var retryAvailable = false
    @Published var lastReceipt: TransferReceipt?
    @Published var transferStartedAt: Date?

    private var recovery: TransferRecovery?
    private var recoveryDestination: URL?
    private var recoveryMustVerify = false
    private var observedDisconnectDuringTransfer = false
    private var transferFinishedAt: Date?

    private var transferControl: TransferControl?
    private var benchmarkControl: TransferControl?
    private var benchmarkID = UUID()
    private var transferID = UUID()
    private var selectedDestinationIdentity: DestinationIdentity?
    private var observers: [NSObjectProtocol] = []
    private let ioQueue = DispatchQueue(label: "local.ismail.relay.io", qos: .userInitiated)
    var onWorkSettled: (() -> Void)?

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var hasSelection: Bool { !files.isEmpty }
    var isBusy: Bool { isTransferring }
    var setupStep: Int { page.stepNumber }
    var canGoBack: Bool { page.isSetup && page != .direction && !isTransferring }
    var canContinue: Bool {
        guard !isTransferring else { return false }
        switch page {
        case .direction: return true
        case .files: return !files.isEmpty
        case .destination: return destination != nil && !isBenchmarking
        case .review: return canTransfer
        default: return false
        }
    }
    var canRetry: Bool { retryAvailable && !isTransferring && !isBenchmarking && destination != nil }
    var isResuming: Bool { recovery != nil }
    var verifiedCount: Int {
        isTransferring ? (event?.verifiedFileCount ?? lastReceipt?.files.count ?? 0)
            : (lastReceipt?.files.count ?? event?.verifiedFileCount ?? 0)
    }
    var isCancelled: Bool { event?.phase == .cancelled }
    var elapsedSeconds: TimeInterval {
        guard let transferStartedAt else { return 0 }
        return max(0, (transferFinishedAt ?? Date()).timeIntervalSince(transferStartedAt))
    }
    var estimatedSecondsRemaining: TimeInterval? {
        guard isTransferring, let event,
              event.phase == .copying || event.phase == .verifying else { return nil }
        let rate = max(event.readBytesPerSecond, event.writeBytesPerSecond)
        guard rate > 0 else { return nil }
        return Double(max(0, event.totalWorkBytes - event.completedWorkBytes)) / rate
    }
    var retryStatus: String? {
        guard isTransferring, let message = event?.message,
              message.localizedCaseInsensitiveContains("retry") else { return nil }
        return message
    }
    var failureTitle: String {
        isCancelled ? "Transfer cancelled" : "Transfer interrupted"
    }
    var failureAdvice: String {
        let message = (errorMessage ?? "").lowercased()
        if message.contains("space") || message.contains("quota") {
            return "Free some space on the destination, then retry. Verified copies will be reused."
        }
        if message.contains("permission") || message.contains("denied") || message.contains("not permitted") {
            return "Check access to the selected files and destination, then retry."
        }
        if message.contains("changed") || message.contains("disconnected") || message.contains("device") {
            return direction == .toDrive
                ? "Check the drive and cable. If you reconnected the drive, choose the same destination again, then retry."
                : "Reconnect the source drive and check its cable, then retry. Relay will check the reconnected files before continuing."
        }
        if message.contains("unfinished") || message.contains("incomplete file") {
            return "Choose a new, empty destination folder. Relay cannot safely replace the unfinished file left on this drive."
        }
        if message.contains("already exists") || message.contains("same destination name") {
            return "Choose an empty destination folder, or rename the conflicting file. Existing files are protected."
        }
        if message.contains("verification") {
            return "Check the cable or port before starting again. The saved copy did not pass verification."
        }
        if isCancelled { return "You can continue with the same files. Completed, verified copies will be reused." }
        return "Check the destination and try again. Completed copies and any originals already moved to Trash are recorded in the receipt."
    }
    var canTransfer: Bool {
        !files.isEmpty && destination != nil && !isTransferring && !isBenchmarking && !completed
    }
    var destinationName: String {
        guard let destination else { return "Choose a destination" }
        return (try? destination.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? destination.lastPathComponent
    }
    var receiptsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay/Receipts", isDirectory: true)
    }

    init() {
        refreshVolumes()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    if name == NSWorkspace.didUnmountNotification {
                        if self?.isTransferring == true { self?.observedDisconnectDuringTransfer = true }
                        if self?.recovery != nil { self?.recoveryMustVerify = true }
                    }
                    self?.refreshVolumes()
                }
            })
        }
    }

    func refreshVolumes() {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey,
            .volumeIsReadOnlyKey, .volumeAvailableCapacityKey, .volumeIsLocalKey]
        volumes = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.volumeIsInternal == false, values.volumeIsLocal == true else { return nil }
                return DriveVolume(url: url, name: values.volumeName ?? url.lastPathComponent,
                    availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                    isInternal: false, isReadOnly: values.volumeIsReadOnly ?? true)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let destination, !FileManager.default.fileExists(atPath: destination.path), !isTransferring {
            cancelBenchmark()
            self.destination = nil
            benchmark = nil
            if recovery != nil { recoveryMustVerify = true }
            errorMessage = "The destination was disconnected. Reconnect it and choose the destination again."
        }
    }

    private func isInternal(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        guard values.volumeIsLocal == true, let internalVolume = values.volumeIsInternal else {
            throw SelectionError.message("Choose a folder on this Mac or a directly connected drive.")
        }
        return internalVolume
    }

    func changeDirection(_ value: TransferDirection) {
        guard !isTransferring, direction != value else { return }
        cancelBenchmark()
        direction = value
        files.removeAll()
        destination = nil
        selectedDestinationIdentity = nil
        benchmark = nil
        benchmarkStatus = "Choose a destination to measure its speed."
        benchmarkError = nil
        resetResult()
        navigate(to: .direction)
    }

    func addFiles(_ urls: [URL]) {
        guard !isTransferring else { return }
        do {
            var additions: [QueuedFile] = []
            for incoming in urls {
                let url = incoming.standardizedFileURL
                guard url.isFileURL else { throw SelectionError.message("Drop files from Finder.") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SelectionError.message("Choose individual files. Folders and symbolic links aren’t supported.")
                }
                let internalVolume = try isInternal(url)
                guard internalVolume == (direction == .toDrive) else {
                    throw SelectionError.message(direction == .toDrive
                        ? "For Mac to Drive, choose source files on your Mac."
                        : "For Drive to Mac, choose source files on a connected drive.")
                }
                guard !files.contains(where: { $0.url == url }),
                      !additions.contains(where: { $0.url == url }) else { continue }
                additions.append(QueuedFile(url: url, name: url.lastPathComponent,
                                            size: Int64(values.fileSize ?? 0)))
            }
            files.append(contentsOf: additions)
            if !additions.isEmpty {
                resetResult()
                if page == .direction || !page.isSetup { navigate(to: .files) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseFiles() {
        guard !isTransferring else { return }
        let panel = NSOpenPanel()
        panel.title = direction == .toDrive ? "Choose files on your Mac" : "Choose files on a drive"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if direction == .toMac { panel.directoryURL = volumes.first?.url }
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func chooseDestination() {
        guard !isTransferring else { return }
        let panel = NSOpenPanel()
        panel.title = direction == .toDrive ? "Choose a drive or a folder on it" : "Choose a folder on your Mac"
        panel.prompt = "Choose Destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = direction == .toDrive ? volumes.first?.url
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { selectDestination(url) }
    }

    func selectDestination(_ incoming: URL) {
        guard !isTransferring else { return }
        do {
            let url = incoming.standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsReadOnlyKey])
            guard values.isDirectory == true else { throw SelectionError.message("Choose a destination folder or drive.") }
            guard values.volumeIsReadOnly != true,
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw SelectionError.message("This destination is read-only. Choose a writable folder or drive.")
            }
            guard try isInternal(url) == (direction == .toMac) else {
                throw SelectionError.message(direction == .toDrive
                    ? "Choose a destination on a connected external drive."
                    : "Choose a destination folder on your Mac.")
            }
            let identity = try DestinationIdentity(folder: url)
            let keepRecovery = recoveryDestination == url && recovery != nil
            cancelBenchmark()
            destination = url
            selectedDestinationIdentity = identity
            benchmark = nil
            if !keepRecovery { resetResult() }
            else {
                errorMessage = nil
                statusMessage = "Destination selected. Ready to resume."
            }
            if page == .direction || !page.isSetup { navigate(to: .destination) }
            testSpeed()
        } catch { errorMessage = error.localizedDescription }
    }

    func testSpeed() {
        guard !isTransferring, let folder = destination,
              let identity = selectedDestinationIdentity else { return }
        cancelBenchmark()
        let control = TransferControl()
        let token = UUID()
        benchmarkControl = control
        benchmarkID = token
        isBenchmarking = true
        benchmark = nil
        benchmarkError = nil
        benchmarkStatus = "Measuring destination speed…"
        ioQueue.async { [self] in
            let result = Result {
                try DiskBenchmark.run(at: folder, expectedDestination: identity, control: control) { message in
                    Task { @MainActor [weak self] in
                        guard self?.benchmarkID == token else { return }
                        self?.benchmarkStatus = message
                    }
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.benchmarkID == token else { return }
                self.isBenchmarking = false
                self.benchmarkControl = nil
                switch result {
                case .success(let value):
                    self.benchmark = value
                    self.benchmarkStatus = "Destination speed · 256 MB test"
                case .failure(let error) where error is CancellationError:
                    self.benchmarkStatus = "Speed test cancelled."
                case .failure(let error):
                    self.benchmarkStatus = "Speed test unavailable."
                    self.benchmarkError = error.localizedDescription
                }
                self.onWorkSettled?()
            }
        }
    }

    func cancelBenchmark() {
        benchmarkControl?.cancel()
        benchmarkControl = nil
        benchmarkID = UUID()
        isBenchmarking = false
    }

    func startTransfer() {
        guard canTransfer, let destination, let identity = selectedDestinationIdentity else { return }
        do {
            guard try DestinationIdentity(folder: destination) == identity,
                  try isInternal(destination) == (direction == .toMac) else {
                throw SelectionError.message("The destination changed or was reconnected. Choose it again before transferring.")
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let request = TransferRequest(sources: files.map(\.url), destination: destination,
                                      disposition: disposition, expectedDestination: identity)
        let control = TransferControl()
        let retainedRecovery = recovery
        let shouldRebind = retainedRecovery != nil
        let forceRecoveryVerification = recoveryMustVerify
        let token = UUID()
        transferID = token
        transferControl = control
        observedDisconnectDuringTransfer = false
        isTransferring = true
        completed = false
        errorMessage = nil
        transferStartedAt = transferStartedAt ?? Date()
        transferFinishedAt = nil
        event = TransferEvent(phase: .preparing, fileCount: files.count,
                              verifiedFileCount: lastReceipt?.files.count ?? 0)
        statusMessage = "Preparing your transfer…"
        retryAvailable = false
        navigate(to: .progress)
        ioQueue.async { [self] in
            let reportProgress: @Sendable (TransferEvent) -> Void = { [self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.isTransferring, self.transferID == token else { return }
                    self.event = event
                    if self.transferControl?.isCancelled != true {
                        self.statusMessage = event.message.isEmpty ? event.phase.title : event.message
                    }
                }
            }
            let result = Result {
                var context = retainedRecovery
                if shouldRebind, let retainedRecovery {
                    context = try retainedRecovery.rebound(to: destination, expectedDestination: identity,
                        forceVerification: forceRecoveryVerification, control: control, progress: reportProgress)
                }
                return try TransferEngine.run(request, recovery: context, control: control, progress: reportProgress)
            }
            Task { @MainActor [weak self] in
                guard self?.transferID == token else { return }
                self?.finish(result)
            }
        }
    }

    private func finish(_ result: Result<TransferReceipt, Error>) {
        isTransferring = false
        transferControl = nil
        transferFinishedAt = Date()
        switch result {
        case .success(let receipt):
            completed = true
            lastReceipt = receipt
            recovery = nil
            recoveryDestination = nil
            recoveryMustVerify = false
            retryAvailable = false
            event = TransferEvent(phase: .complete, fileCount: files.count,
                completedWorkBytes: totalBytes * 2, totalWorkBytes: totalBytes * 2,
                verifiedFileCount: receipt.files.count)
            statusMessage = disposition == .keep
                ? "Every file verified. Originals kept."
                : "Every file verified. Originals moved to Trash."
            saveReceipt(receipt)
            navigate(to: .success)
        case .failure(let failure as TransferRunFailure):
            lastReceipt = failure.receipt
            recovery = failure.recovery
            recoveryDestination = failure.recovery == nil ? nil : destination
            recoveryMustVerify = recoveryMustVerify || observedDisconnectDuringTransfer
            retryAvailable = failure.isRetryable || (failure.isCancellation && failure.receipt.files.isEmpty)
            let phase: TransferPhase = failure.isCancellation ? .cancelled : .failed
            event = TransferEvent(phase: phase, fileCount: files.count,
                                  verifiedFileCount: failure.receipt.files.count)
            statusMessage = failure.isCancellation ? "Transfer cancelled. Verified copies are kept." : "Transfer stopped."
            errorMessage = failure.localizedDescription
            if !failure.receipt.files.isEmpty { saveReceipt(failure.receipt, failure: failure.localizedDescription) }
            navigate(to: .recovery)
        case .failure(let error) where error is CancellationError:
            retryAvailable = true
            event = TransferEvent(phase: .cancelled, fileCount: files.count,
                                  verifiedFileCount: event?.verifiedFileCount ?? 0)
            statusMessage = "Transfer cancelled. Any completed, verified copies are kept."
            navigate(to: .recovery)
        case .failure(let error):
            retryAvailable = false
            let count = event?.verifiedFileCount ?? 0
            event = TransferEvent(phase: .failed, fileCount: files.count, verifiedFileCount: count)
            statusMessage = "Transfer stopped."
            errorMessage = error.localizedDescription
            navigate(to: .recovery)
        }
        onWorkSettled?()
    }

    private func saveReceipt(_ receipt: TransferReceipt, failure: String? = nil) {
        do {
            try FileManager.default.createDirectory(at: receiptsFolder, withIntermediateDirectories: true)
            let url = receiptsFolder.appendingPathComponent("Transfer-\(receipt.id.uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var object = try JSONSerialization.jsonObject(with: encoder.encode(receipt)) as! [String: Any]
            object["status"] = failure == nil ? "complete" : "incomplete"
            if let failure { object["failure"] = failure }
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
            receiptURL = url
        } catch {
            errorMessage = [errorMessage, "The verification receipt could not be saved: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }

    func stopBeforeQuitting(completion: @escaping () -> Void) {
        if isTransferring {
            onWorkSettled = completion
            cancelTransfer()
        } else {
            cancelBenchmark()
            ioQueue.async { DispatchQueue.main.async(execute: completion) }
        }
    }

    func cancelTransfer() {
        guard isTransferring else { return }
        statusMessage = "Stopping safely…"
        transferControl?.cancel()
    }

    func removeFile(_ id: UUID) {
        guard !isTransferring else { return }
        files.removeAll { $0.id == id }
        resetResult()
    }

    func clearFiles() {
        guard !isTransferring else { return }
        files.removeAll()
        resetResult()
    }

    private func resetResult() {
        event = nil
        completed = false
        receiptURL = nil
        errorMessage = nil
        statusMessage = "Ready when you are."
        recovery = nil
        recoveryDestination = nil
        recoveryMustVerify = false
        observedDisconnectDuringTransfer = false
        lastReceipt = nil
        retryAvailable = false
        transferStartedAt = nil
        transferFinishedAt = nil
    }

    func newTransfer() {
        guard !isTransferring else { return }
        cancelBenchmark()
        clearFiles()
        destination = nil
        selectedDestinationIdentity = nil
        benchmark = nil
        benchmarkError = nil
        disposition = .keep
        navigate(to: .direction)
    }

    func continueSetup() {
        guard canContinue else { return }
        switch page {
        case .direction: navigate(to: .files)
        case .files: navigate(to: .destination)
        case .destination: navigate(to: .review)
        case .review: startTransfer()
        default: break
        }
    }

    func goBack() {
        guard canGoBack, let previous = RelayPage(rawValue: page.rawValue - 1) else { return }
        navigate(to: previous)
    }

    func showSetupStep(_ step: RelayPage) {
        guard !isTransferring, step.isSetup, !completed else { return }
        if step == .review && (files.isEmpty || destination == nil) { return }
        if step == .destination && files.isEmpty { return }
        navigate(to: step)
    }

    func retryTransfer() {
        guard canRetry else { return }
        completed = false
        startTransfer()
    }

    func editTransfer() {
        guard !isTransferring else { return }
        completed = false
        navigate(to: files.isEmpty ? .files : destination == nil ? .destination : .review)
    }

    func editFiles() {
        guard !isTransferring else { return }
        completed = false
        navigate(to: .files)
    }

    func editDestination() {
        guard !isTransferring else { return }
        completed = false
        navigate(to: .destination)
    }

    private func navigate(to next: RelayPage) {
        navigationDirection = next.rawValue >= page.rawValue ? 1 : -1
        page = next
    }

    func dismissError() { errorMessage = nil }
    func revealDestination() { if let destination { NSWorkspace.shared.open(destination) } }
    func revealReceipt() {
        if let receiptURL { NSWorkspace.shared.activateFileViewerSelecting([receiptURL]) }
    }
    func showReceipts() {
        do {
            try FileManager.default.createDirectory(at: receiptsFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(receiptsFolder)
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum SelectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
