import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// exFAT does not provide sparse allocation. Write the entire disk with a bounded buffer.
/// The final name is published only after all bytes have been written and synchronized.
enum FullDiskWriter {
    static func create(at final: URL, bytes: UInt64,
                       cancelled: () -> Bool = { false },
                       progress: (UInt64, UInt64) -> Void = { _, _ in }) throws {
        guard bytes > 0, bytes <= UInt64(Int64.max) else {
            throw failure("Invalid disk size.")
        }
        let fm = FileManager.default
        let partial = final.appendingPathExtension("allocating")
        guard !fm.fileExists(atPath: final.path) else { throw failure("The disk already exists; it was not changed.") }
        let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posixFailure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var published = false
        defer {
            try? handle.close()
            if !published { try? fm.removeItem(at: partial) }
        }
        let zeros = Data(repeating: 0, count: 1 << 20)
        var done: UInt64 = 0
        while done < bytes {
            if cancelled() { throw CancellationError() }
            let count = Int(min(UInt64(zeros.count), bytes - done))
            try handle.write(contentsOf: zeros.prefix(count))
            done += UInt64(count)
            if done == bytes || done % (64 << 20) == 0 { progress(done, bytes) }
        }
        try handle.synchronize()
        try handle.close()
        // moveItem refuses an existing destination. Never replace a disk, even in a race.
        try fm.moveItem(at: partial, to: final)
        published = true
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Henge.ExternalDisk", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
