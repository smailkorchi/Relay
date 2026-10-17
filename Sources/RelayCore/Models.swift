import Foundation

public enum TransferDirection: String, CaseIterable, Sendable {
    case toDrive, toMac
    public var title: String { self == .toDrive ? "Mac to Drive" : "Drive to Mac" }
}

public enum SourceDisposition: String, CaseIterable, Codable, Sendable {
    case keep, trashAfterVerification
    public var title: String { self == .keep ? "Keep originals" : "Move originals to Trash" }
}

public enum TransferPhase: String, Codable, Sendable {
    case preparing, copying, flushing, verifying, movingOriginals, complete, cancelled, failed
    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .copying: "Copying"
        case .flushing: "Saving to disk"
        case .verifying: "Verifying"
        case .movingOriginals: "Moving originals to Trash"
        case .complete: "Complete"
        case .cancelled: "Cancelled"
        case .failed: "Transfer stopped"
        }
    }
}

public struct TransferRequest: Sendable {
    public var sources: [URL]
    public var destination: URL
    public var disposition: SourceDisposition
    public var expectedDestination: DestinationIdentity?
    public init(sources: [URL], destination: URL, disposition: SourceDisposition = .keep,
                expectedDestination: DestinationIdentity? = nil) {
        self.sources = sources
        self.destination = destination
        self.disposition = disposition
        self.expectedDestination = expectedDestination
    }
}

public struct TransferEvent: Sendable {
    public var phase: TransferPhase
    public var fileIndex: Int
    public var fileCount: Int
    public var filename: String
    public var fileBytesDone: Int64
    public var fileBytesTotal: Int64
    public var completedWorkBytes: Int64
    public var totalWorkBytes: Int64
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var verifiedFileCount: Int
    public var message: String
    public init(phase: TransferPhase, fileIndex: Int = 0, fileCount: Int = 0,
                filename: String = "", fileBytesDone: Int64 = 0, fileBytesTotal: Int64 = 0,
                completedWorkBytes: Int64 = 0, totalWorkBytes: Int64 = 0,
                readBytesPerSecond: Double = 0, writeBytesPerSecond: Double = 0,
                verifiedFileCount: Int = 0, message: String = "") {
        self.phase = phase; self.fileIndex = fileIndex; self.fileCount = fileCount
        self.filename = filename; self.fileBytesDone = fileBytesDone; self.fileBytesTotal = fileBytesTotal
        self.completedWorkBytes = completedWorkBytes; self.totalWorkBytes = totalWorkBytes
        self.readBytesPerSecond = readBytesPerSecond; self.writeBytesPerSecond = writeBytesPerSecond
        self.verifiedFileCount = verifiedFileCount; self.message = message
    }
    public var fractionCompleted: Double {
        phase == .complete ? 1 : min(0.995, Double(completedWorkBytes) / Double(max(totalWorkBytes, 1)))
    }
}

public struct VerifiedFileReceipt: Codable, Sendable {
    public var sourcePath: String
    public var destinationPath: String
    public var byteCount: Int64
    public var sha256: String
    public var originalTrashed: Bool
    public var trashPath: String?
    public init(sourcePath: String, destinationPath: String, byteCount: Int64, sha256: String,
                originalTrashed: Bool = false, trashPath: String? = nil) {
        self.sourcePath = sourcePath; self.destinationPath = destinationPath
        self.byteCount = byteCount; self.sha256 = sha256
        self.originalTrashed = originalTrashed; self.trashPath = trashPath
    }
}

public struct TransferReceipt: Codable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var completedAt: Date
    public var disposition: SourceDisposition
    public var files: [VerifiedFileReceipt]
    public init(id: UUID = UUID(), startedAt: Date, completedAt: Date = Date(),
                disposition: SourceDisposition, files: [VerifiedFileReceipt]) {
        self.id = id; self.startedAt = startedAt; self.completedAt = completedAt
        self.disposition = disposition; self.files = files
    }
}

public struct BenchmarkResult: Sendable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var testedBytes: Int64
    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, testedBytes: Int64) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.testedBytes = testedBytes
    }
}

public final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func checkCancellation() throws { if isCancelled { throw CancellationError() } }
}
