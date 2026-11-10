import Foundation

@main
struct DownloadTests {
    static func check(_ value: Bool, _ text: String) throws {
        if !value { throw RestoreImageStore.failure(text) }
    }

    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("henge-http-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        func store(_ path: String) -> RestoreImageStore {
            RestoreImageStore(url: root.appendingPathComponent(path + ".ipsw"), source: base.appendingPathComponent(path))
        }
        func fetch(_ store: RestoreImageStore) async throws -> URL {
            try await RestoreImageDownload(store: store, progress: { _, _ in }).start()
        }

        let plain = store("plain")
        let plainURL = try await fetch(plain)
        let plainData = try Data(contentsOf: plainURL)
        try check(plainData == expected && plain.completeSize == Int64(expected.count), "HTTP 200 body or receipt is wrong")
        print("PASS real HTTP 200 streams into the selected destination")

        let drop = store("drop")
        var interrupted = false
        do { _ = try await fetch(drop) } catch { interrupted = true }
        try check(interrupted && drop.completeSize == nil, "Interrupted HTTP response was accepted")
        let partial = try drop.resumeState()
        try FileHandle.standardError.write(contentsOf: Data("Interrupted HTTP: retained \(partial.offset) bytes; partial size \(partial.partialSize ?? -1)\n".utf8))
        try check(partial.offset > 0 && partial.offset <= 65536, "Interrupted body was not retained for resuming")
        let retained = try Data(contentsOf: drop.partial)
        try check(retained == expected.prefix(Int(partial.offset)), "Interrupted partial contains wrong bytes")
        let resumedURL = try await fetch(drop)
        let resumedData = try Data(contentsOf: resumedURL)
        try check(resumedData == expected, "Real HTTP Range/If-Range resume corrupted bytes")
        print("PASS real disconnect resumes with Range and If-Range")

        for path in ["ignore", "wrong-range"] {
            let image = store(path)
            let file = try image.openForResponse(bytes: Int64(expected.count), validator: "\"henge-fixture-v1\"", offset: 0)
            try file.write(contentsOf: expected.prefix(65536))
            try file.close()
            if path == "ignore" {
                let url = try await fetch(image)
                let data = try Data(contentsOf: url)
                try check(data == expected, "HTTP 200 ignored-Range response was appended")
                print("PASS real ignored Range restarts without old trailing bytes")
            } else {
                var rejected = false
                do { _ = try await fetch(image) } catch { rejected = true }
                let bytes = try Data(contentsOf: image.partial)
                try check(rejected && bytes == expected.prefix(65536) && image.completeSize == nil, "Wrong Content-Range changed the partial")
                print("PASS real wrong Content-Range cannot change the partial")
            }
        }

        let missing = store("missing")
        var rejected = false
        do { _ = try await fetch(missing) } catch { rejected = true }
        try check(rejected && !FileManager.default.fileExists(atPath: missing.partial.path), "HTTP error created a restore image")
        print("PASS real HTTP errors do not create restore image files")
        print("5 streaming HTTP integration tests passed.")
    }
}
