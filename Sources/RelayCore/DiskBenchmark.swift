import Foundation
import CryptoKit
import Darwin

public enum DiskBenchmark {
    public static func run(at folder: URL, byteCount: Int64 = 256 * 1024 * 1024,
                           expectedDestination: DestinationIdentity? = nil,
                           control: TransferControl,
                           progress: @escaping @Sendable (String) -> Void) throws -> BenchmarkResult {
        guard byteCount > 0 else { throw TransferFailure("Choose a positive test size.") }
        try control.checkCancellation()
        let destination = try PinnedFolder(folder)
        if let expectedDestination, expectedDestination != destination.identity {
            throw TransferFailure("The selected destination changed. Select the destination again before testing its speed.")
        }
        try destination.requireSpace(byteCount)
        let name = ".relay-speed-\(UUID().uuidString).partial"
        var descriptor = try destination.createExclusive(name)
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            destination.removeOwnedTemporary(name)
        }
        try FileIO.uncached(descriptor)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileIO.bufferSize, alignment: 4096)
        defer { buffer.deallocate() }
        arc4random_buf(buffer, FileIO.bufferSize)
        var hash = SHA256()
        var remaining = byteCount
        var lastReport = ProcessInfo.processInfo.systemUptime
        let writeStart = lastReport
        progress("Measuring write speed…")
        while remaining > 0 {
            try control.checkCancellation()
            try destination.check()
            let amount = Int(min(remaining, Int64(FileIO.bufferSize)))
            hash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
            try FileIO.writeAll(descriptor, from: buffer, count: amount)
            remaining -= Int64(amount)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.2 {
                progress("Writing test file · \(Int(Double(byteCount - remaining) / Double(byteCount) * 100))%")
                lastReport = now
            }
        }
        try FileIO.flush(descriptor)
        let writtenIdentity = try FileIdentity(descriptor: descriptor)
        let writeElapsed = ProcessInfo.processInfo.systemUptime - writeStart
        let writtenFD = descriptor
        descriptor = -1
        try FileIO.closeChecked(writtenFD)
        try control.checkCancellation()
        progress("Measuring read speed and verifying test data…")
        descriptor = try destination.openRead(name)
        try FileIO.uncached(descriptor)
        guard try FileIdentity(descriptor: descriptor) == writtenIdentity else {
            throw TransferFailure("The speed-test file changed before verification.")
        }
        let readStart = ProcessInfo.processInfo.systemUptime
        var savedHash = SHA256()
        var readBytes: Int64 = 0
        while true {
            try control.checkCancellation()
            try destination.check()
            let amount = try FileIO.read(descriptor, into: buffer, count: FileIO.bufferSize)
            if amount == 0 { break }
            readBytes += Int64(amount)
            guard readBytes <= byteCount else { throw TransferFailure("The speed-test file changed during the test.") }
            savedHash.update(data: Data(bytesNoCopy: buffer, count: amount, deallocator: .none))
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.2 {
                progress("Reading test file · \(Int(Double(readBytes) / Double(byteCount) * 100))%")
                lastReport = now
            }
        }
        let readElapsed = ProcessInfo.processInfo.systemUptime - readStart
        guard readBytes == byteCount, hash.finalize() == savedHash.finalize() else {
            throw TransferFailure("Speed-test verification failed. The drive did not return the data it saved.")
        }
        try destination.check()
        try destination.requireUnchanged(name, identity: writtenIdentity)
        let verifiedFD = descriptor
        descriptor = -1
        try FileIO.closeChecked(verifiedFD)
        try destination.removeOwnedTemporaryChecked(name)
        return BenchmarkResult(readBytesPerSecond: Double(byteCount) / max(readElapsed, 0.001),
                               writeBytesPerSecond: Double(byteCount) / max(writeElapsed, 0.001),
                               testedBytes: byteCount)
    }
}
