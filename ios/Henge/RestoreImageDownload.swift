import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A restore image goes straight to its destination volume. URLSession download tasks
/// first stage the entire IPSW in the app's internal temporary directory.
struct RestoreImageStore {
    let url: URL
    let source: URL
    var partial: URL { url.appendingPathExtension("part") }
    private var metadataURL: URL { url.appendingPathExtension("download.json") }
    private var receiptURL: URL { url.appendingPathExtension("complete.json") }

    struct Metadata: Codable {
        let source: String
        let bytes: Int64
        let validator: String?
    }

    var completeSize: Int64? {
        guard let receipt = try? readMetadata(receiptURL), receipt.source == source.absoluteString,
              receipt.bytes > 0, (try? regularSize(url)) == receipt.bytes else { return nil }
        return receipt.bytes
    }

    func resumeState() throws -> (offset: Int64, metadata: Metadata?, partialSize: Int64?) {
        // Never silently replace an existing image without its completion receipt.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Self.failure("An unverified restore image already exists at \(url.lastPathComponent). Choose another USB folder or inspect the file before retrying.")
        }
        guard FileManager.default.fileExists(atPath: partial.path) else { return (0, nil, nil) }
        let count = try regularSize(partial)
        let metadata = try readMetadata(metadataURL)
        guard metadata.source == source.absoluteString, metadata.bytes > 0,
              count >= 0, count <= metadata.bytes else {
            throw Self.failure("The partial download belongs to a different image or is damaged. It was not changed.")
        }
        // If-Range needs an HTTP validator. Without one, restart this owned partial.
        return (metadata.validator == nil ? 0 : count, metadata, count)
    }

    func openForResponse(bytes: Int64, validator: String?, offset: Int64, expectedPartialSize: Int64? = nil) throws -> FileHandle {
        guard bytes > 0, offset >= 0, offset < bytes else { throw Self.failure("Invalid restore download size.") }
        let flags = O_WRONLY | O_NOFOLLOW | (expectedPartialSize == nil ? O_CREAT | O_EXCL : 0)
        let fd = open(partial.path, flags, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_size == (expectedPartialSize ?? 0), offset == 0 || info.st_size == offset else {
                throw Self.failure("The partial download changed while it was being opened.")
            }
            if offset == 0 { try file.truncate(atOffset: 0) }
            try file.seek(toOffset: UInt64(offset))
            try writeMetadata(Metadata(source: source.absoluteString, bytes: bytes, validator: validator), to: metadataURL)
            return file
        } catch {
            try? file.close()
            throw error
        }
    }

    func publish(bytes: Int64, validator: String?) throws {
        guard bytes > 0, try regularSize(partial) == bytes else {
            throw Self.failure("The restore download is incomplete. Its partial file was kept for retrying.")
        }
        // A publication race must not leave a valid-looking receipt on someone else's file.
        // A crash between rename and receipt leaves an unverified image that is kept, never overwritten.
        try FileManager.default.moveItem(at: partial, to: url)
        try writeMetadata(Metadata(source: source.absoluteString, bytes: bytes, validator: validator), to: receiptURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    func removeCompletedImage() throws {
        guard completeSize != nil else { throw Self.failure("This is not a completed Henge download.") }
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: receiptURL)
    }

    func finishFullPartial(_ metadata: Metadata) throws {
        let fd = open(partial.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size == metadata.bytes else {
            throw Self.failure("The partial download changed before completion.")
        }
        try file.synchronize()
        try file.close()
        try publish(bytes: metadata.bytes, validator: metadata.validator)
    }

    private func regularSize(_ path: URL) throws -> Int64 {
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw Self.failure("A restore download path is not a regular file.")
        }
        return Int64(size)
    }

    private func readMetadata(_ path: URL) throws -> Metadata {
        guard try regularSize(path) < 16_384 else { throw Self.failure("Invalid download metadata.") }
        return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: path))
    }

    private func writeMetadata(_ value: Metadata, to path: URL) throws {
        if FileManager.default.fileExists(atPath: path.path) { _ = try regularSize(path) }
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "Henge.RestoreDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// HTTP response validation is separate from I/O so bad range replies can be tested.
struct RestoreDownloadResponse {
    let offset: Int64
    let bytes: Int64
    let validator: String?

    static func parse(_ response: HTTPURLResponse, requestedOffset: Int64,
                      previous: RestoreImageStore.Metadata?) throws -> Self {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else {
            throw RestoreImageStore.failure("Apple returned an encoded restore download; it was not used.")
        }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let validator = (etag?.hasPrefix("W/") == false ? etag : nil)
            ?? response.value(forHTTPHeaderField: "Last-Modified")
        if response.statusCode == 200 {
            guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > 0 else {
                throw RestoreImageStore.failure("The restore server did not provide a valid file size.")
            }
            // A server can ignore Range or replace the resource. Start again; never append.
            return Self(offset: 0, bytes: length, validator: validator)
        }
        guard response.statusCode == 206, requestedOffset > 0, let previous,
              let oldValidator = previous.validator, validator == oldValidator,
              let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else {
            throw RestoreImageStore.failure("The restore server answered HTTP \(response.statusCode) without a matching download range. The partial file was kept.")
        }
        let pieces = header.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int64(pieces[1]), total == previous.bytes else {
            throw RestoreImageStore.failure("The restore download size changed during resuming.")
        }
        let range = pieces[0].split(separator: "-")
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]),
              start == requestedOffset, start >= 0, end >= start, total > end, end == total - 1,
              let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length == total - start else {
            throw RestoreImageStore.failure("The restore server returned the wrong byte range. Nothing was appended.")
        }
        return Self(offset: start, bytes: total, validator: validator)
    }
}

/// All mutable state is confined to URLSession's serial delegate queue after start().
final class RestoreImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let store: RestoreImageStore
    private let progress: (Int64, Int64) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var file: FileHandle?
    private var metadata: RestoreImageStore.Metadata?
    private var response: RestoreDownloadResponse?
    private var offset: Int64 = 0
    private var partialSize: Int64?
    private var received: Int64 = 0
    private var failure: Error?
    private var lastProgress: Int64 = 0

    init(store: RestoreImageStore, progress: @escaping (Int64, Int64) -> Void) {
        self.store = store
        self.progress = progress
    }

    func start() async throws -> URL {
        if store.completeSize != nil { return store.url }
        (offset, metadata, partialSize) = try store.resumeState()
        if let metadata, offset == metadata.bytes {
            try store.finishFullPartial(metadata)
            return store.url
        }
        var request = URLRequest(url: store.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0, let validator = metadata?.validator {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 48 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw RestoreImageStore.failure("Invalid restore server response.") }
            let parsed = try RestoreDownloadResponse.parse(http, requestedOffset: offset, previous: metadata)
            file = try store.openForResponse(bytes: parsed.bytes, validator: parsed.validator, offset: parsed.offset,
                                            expectedPartialSize: partialSize)
            self.response = parsed
            received = parsed.offset
            lastProgress = received
            progress(received, parsed.bytes)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let file, let response else { return }
        do {
            guard Int64(data.count) <= response.bytes - received else {
                throw RestoreImageStore.failure("The restore server sent more data than the announced file size.")
            }
            try file.write(contentsOf: data)
            received += Int64(data.count)
            if received == response.bytes || received - lastProgress >= (1 << 20) {
                lastProgress = received
                progress(received, response.bytes)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var result: Result<URL, Error>
        do {
            if let failure = failure ?? error { throw failure }
            guard let response, received == response.bytes else {
                throw RestoreImageStore.failure("The restore download ended early. Its partial file was kept.")
            }
            try file?.synchronize()
            try file?.close()
            file = nil
            try store.publish(bytes: response.bytes, validator: response.validator)
            result = .success(store.url)
        } catch {
            try? file?.synchronize()
            try? file?.close()
            file = nil
            result = .failure(error)
        }
        continuation?.resume(with: result)
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
