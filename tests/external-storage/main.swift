import Foundation

// Standalone executable tests: compile the SAME writer and storage definitions as the app.
// Security-scoped picker access is exercised by the iPad probe, not mocked as successful here.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("henge-storage-tests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var passed = 0

func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
    guard value() else { throw NSError(domain: "StorageTest", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
}
func test(_ name: String, _ body: () throws -> Void) throws {
    try body()
    passed += 1
    print("PASS \(name)")
}
func mustThrow(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "StorageTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected failure"])
}

try test("Exact non-aligned size, zero bytes and monotonic completion") {
    let path = root.appendingPathComponent("odd.img")
    let bytes: UInt64 = (2 << 20) + 17
    var last: UInt64 = 0
    try FullDiskWriter.create(at: path, bytes: bytes) { done, total in
        precondition(done >= last && total == bytes)
        last = done
    }
    let data = try Data(contentsOf: path)
    try check(data.count == Int(bytes) && data.allSatisfy { $0 == 0 } && last == bytes, "size/contents/progress")
    try check(!fm.fileExists(atPath: path.appendingPathExtension("allocating").path), "partial disappeared")
}
try test("Random write survives close and reopen") {
    let path = root.appendingPathComponent("odd.img")
    let marker = Data("HENGE RANDOM WRITE".utf8)
    let writer = try FileHandle(forUpdating: path)
    try writer.seek(toOffset: 1_048_593)
    try writer.write(contentsOf: marker)
    try writer.synchronize()
    try writer.close()
    let reader = try FileHandle(forReadingFrom: path)
    defer { try? reader.close() }
    try reader.seek(toOffset: 1_048_593)
    let read = try reader.read(upToCount: marker.count)
    try check(read == marker, "reopened random data")
}
try test("Existing final disk remains unchanged") {
    let path = root.appendingPathComponent("existing.img")
    let original = Data("DO NOT CHANGE".utf8)
    try original.write(to: path)
    try mustThrow { try FullDiskWriter.create(at: path, bytes: 4096) }
    let after = try Data(contentsOf: path)
    try check(after == original, "existing file overwritten")
}
try test("Existing partial remains unchanged") {
    let path = root.appendingPathComponent("partial.img")
    let partial = path.appendingPathExtension("allocating")
    let original = Data("OTHER INCOMPLETE FILE".utf8)
    try original.write(to: partial)
    try mustThrow { try FullDiskWriter.create(at: path, bytes: 4096) }
    let after = try Data(contentsOf: partial)
    try check(after == original && !fm.fileExists(atPath: path.path), "existing partial changed")
}
try test("Cancellation removes only the newly created partial") {
    let path = root.appendingPathComponent("cancel.img")
    var calls = 0
    try mustThrow {
        try FullDiskWriter.create(at: path, bytes: 4 << 20, cancelled: { calls += 1; return calls > 1 })
    }
    try check(!fm.fileExists(atPath: path.path), "cancel published final disk")
    try check(!fm.fileExists(atPath: path.appendingPathExtension("allocating").path), "cancel left partial")
}
try test("A concurrent final file is not replaced") {
    let path = root.appendingPathComponent("race.img")
    let other = Data("CONCURRENT OWNER".utf8)
    try mustThrow {
        try FullDiskWriter.create(at: path, bytes: 4096) { _, _ in try! other.write(to: path) }
    }
    let after = try Data(contentsOf: path)
    try check(after == other, "concurrent final overwritten")
}
try test("Invalid disk sizes create no files") {
    let path = root.appendingPathComponent("invalid.img")
    try mustThrow { try FullDiskWriter.create(at: path, bytes: 0) }
    try mustThrow { try FullDiskWriter.create(at: path, bytes: UInt64.max) }
    try check(!fm.fileExists(atPath: path.path), "invalid disk created")
}
try test("Bookmark and machine ownership survive serialization") {
    let location = ExternalDiskLocation(folder: ExternalDiskFolder(bookmark: Data([1, 2, 3]), name: "USB"),
                                        machineID: UUID(), token: UUID(), bytes: 64 << 30)
    let decoded = try JSONDecoder().decode(ExternalDiskLocation.self, from: JSONEncoder().encode(location))
    try check(decoded == location && !decoded.directoryName.contains("/"), "disk identity changed")
}

let source = URL(string: "https://example.test/restore.ipsw")!
func imageStore(_ name: String) -> RestoreImageStore {
    RestoreImageStore(url: root.appendingPathComponent(name + ".ipsw"), source: source)
}
func http(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: source, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

try test("An interrupted restore download cannot look complete") {
    let store = imageStore("interrupted")
    let file = try store.openForResponse(bytes: 16, validator: "\"first\"", offset: 0)
    try file.write(contentsOf: Data([1, 2, 3, 4]))
    try file.close()
    try check(store.completeSize == nil, "partial reported complete")
    let state = try store.resumeState()
    try check(state.offset == 4 && state.metadata?.bytes == 16, "resume lost the partial size")
    try mustThrow { try store.publish(bytes: 16, validator: "\"first\"") }
}
try test("A matching range appends and publishes the exact complete image") {
    let store = imageStore("interrupted")
    let state = try store.resumeState()
    let response = try RestoreDownloadResponse.parse(http(206, ["Content-Range": "bytes 4-15/16", "Content-Length": "12", "ETag": "\"first\""]),
                                                     requestedOffset: state.offset, previous: state.metadata)
    let file = try store.openForResponse(bytes: response.bytes, validator: response.validator, offset: response.offset,
                                         expectedPartialSize: state.partialSize)
    try file.write(contentsOf: Data(repeating: 5, count: 12))
    try file.synchronize()
    try file.close()
    try store.publish(bytes: response.bytes, validator: response.validator)
    try check(store.completeSize == 16, "completion receipt missing")
    let bytes = try Data(contentsOf: store.url)
    try check(bytes == Data([1, 2, 3, 4]) + Data(repeating: 5, count: 12), "resumed bytes wrong")
    try check(!fm.fileExists(atPath: store.partial.path), "partial remained after publication")
}
try test("A server ignoring Range restarts instead of appending") {
    let store = imageStore("range-ignored")
    var file = try store.openForResponse(bytes: 10, validator: "\"old\"", offset: 0)
    try file.write(contentsOf: Data(repeating: 9, count: 6))
    try file.close()
    let state = try store.resumeState()
    let response = try RestoreDownloadResponse.parse(http(200, ["Content-Length": "3", "ETag": "\"new\""]),
                                                     requestedOffset: state.offset, previous: state.metadata)
    try check(response.offset == 0 && response.bytes == 3, "ignored range was appended")
    file = try store.openForResponse(bytes: response.bytes, validator: response.validator, offset: response.offset,
                                     expectedPartialSize: state.partialSize)
    try file.write(contentsOf: Data([1, 2, 3]))
    try file.close()
    try store.publish(bytes: 3, validator: response.validator)
    let bytes = try Data(contentsOf: store.url)
    try check(bytes == Data([1, 2, 3]), "old trailing bytes remained")
}
try test("Wrong ranges, changed validators and encoded bodies are rejected") {
    let old = RestoreImageStore.Metadata(source: source.absoluteString, bytes: 16, validator: "\"one\"")
    let bad = [
        http(206, ["Content-Range": "bytes 3-15/16", "Content-Length": "13", "ETag": "\"one\""]),
        http(206, ["Content-Range": "bytes 4-15/16", "Content-Length": "12", "ETag": "\"two\""]),
        http(206, ["Content-Range": "bytes 4-16/17", "Content-Length": "13", "ETag": "\"one\""]),
        http(200, ["Content-Length": "16", "Content-Encoding": "gzip"]),
        http(404, ["Content-Length": "16"]),
        http(200, [:])
    ]
    for response in bad {
        try mustThrow { _ = try RestoreDownloadResponse.parse(response, requestedOffset: 4, previous: old) }
    }
}
try test("Unverified existing images and foreign partials are preserved") {
    let store = imageStore("foreign")
    let bytes = Data("USER FILE".utf8)
    try bytes.write(to: store.url)
    try check(store.completeSize == nil, "unverified image treated as downloaded")
    try mustThrow { _ = try store.resumeState() }
    try mustThrow { try store.removeCompletedImage() }
    let after = try Data(contentsOf: store.url)
    try check(after == bytes, "existing image changed")
    let partial = imageStore("foreign-partial")
    try bytes.write(to: partial.partial)
    try mustThrow { _ = try partial.resumeState() }
    let partialAfter = try Data(contentsOf: partial.partial)
    try check(partialAfter == bytes, "foreign partial changed")
}
try test("A download receipt from another source is not accepted") {
    let store = imageStore("interrupted")
    let foreign = RestoreImageStore(url: store.url, source: URL(string: "https://example.test/other.ipsw")!)
    try check(foreign.completeSize == nil, "foreign source accepted")
}
try test("Completed downloads can be deleted without deleting other files") {
    let store = imageStore("range-ignored")
    try store.removeCompletedImage()
    try check(!fm.fileExists(atPath: store.url.path), "complete image not deleted")
    let other = imageStore("foreign")
    try check(fm.fileExists(atPath: other.url.path), "unrelated file deleted")
}
try test("A publication race cannot replace an existing final image") {
    let store = imageStore("download-race")
    let file = try store.openForResponse(bytes: 3, validator: nil, offset: 0)
    try file.write(contentsOf: Data([1, 2, 3]))
    try file.close()
    let other = Data([7, 8, 9]) // same length: a failed publish must not certify it
    try other.write(to: store.url)
    try mustThrow { try store.publish(bytes: 3, validator: nil) }
    let after = try Data(contentsOf: store.url)
    try check(after == other, "concurrent final image was overwritten")
    try check(store.completeSize == nil, "race incorrectly certified someone else's image")
}
try test("A concurrently created partial is not overwritten") {
    let store = imageStore("partial-race")
    let other = Data([7, 8, 9])
    try other.write(to: store.partial)
    try mustThrow { _ = try store.openForResponse(bytes: 8, validator: nil, offset: 0) }
    let after = try Data(contentsOf: store.partial)
    try check(after == other, "concurrent partial was overwritten")
}
try test("USB installs reserve internal RAM without staging the IPSW internally") {
    let ipsw: Int64 = 16_035 << 20
    let internalNeed = InstallSpace.internalBytes(imageBytes: ipsw, haveImage: false, external: true, ramMB: 2048)
    try check(internalNeed == 4 << 30, "external install still stages IPSW internally")
    try check(internalNeed < 7 << 30, "does not fit the user's internal free-space budget")
    try check(InstallSpace.internalBytes(imageBytes: ipsw, haveImage: true, external: true, ramMB: 2048) == internalNeed,
              "USB download cache affects internal-space estimate")
    let usbNeed = InstallSpace.externalBytes(imageBytes: ipsw, haveImage: false)
    try check(usbNeed > 64 << 30 && usbNeed < 292_000_000_000, "USB space estimate does not include staging or exceeds this drive")
    try check(InstallSpace.externalBytes(imageBytes: ipsw, haveImage: true) == usbNeed - ipsw, "completed cache not reused in estimate")
}
func folderFacts(local: Bool? = nil, internalVolume: Bool? = nil, readOnly: Bool? = nil,
                 ubiquitous: Bool? = nil, filesystemLocal: Bool? = true,
                 filesystemReadOnly: Bool? = false, sameAsInternal: Bool? = false,
                 directory: Bool = true, symbolicLink: Bool = false) -> ExternalFolderFacts {
    ExternalFolderFacts(directory: directory, symbolicLink: symbolicLink, local: local,
                        internalVolume: internalVolume, readOnly: readOnly, ubiquitous: ubiquitous,
                        filesystemLocal: filesystemLocal, filesystemReadOnly: filesystemReadOnly,
                        sameAsInternalVolume: sameAsInternal, filesystemType: "test")
}
try test("Complete NSURL metadata still accepts a writable external volume") {
    let facts = folderFacts(local: true, internalVolume: false, readOnly: false,
                            filesystemLocal: nil, filesystemReadOnly: nil, sameAsInternal: nil)
    try check(facts.rejection == nil, "known external volume rejected")
}
try test("Unavailable iPad volume metadata uses independent local mount evidence") {
    let facts = folderFacts()
    try check(facts.local == nil && facts.internalVolume == nil && facts.readOnly == nil,
              "test must represent missing NSURL values")
    try check(facts.rejection == nil, "missing metadata was treated as an internal or read-only volume")
}
try test("A provider's internal staging volume cannot pass as USB") {
    let facts = folderFacts(local: true, internalVolume: false, readOnly: false, sameAsInternal: true)
    try check(facts.rejection != nil, "internal staged provider directory accepted")
}
try test("Network, cloud, read-only, internal and symlink targets stay rejected") {
    let rejected = [folderFacts(local: false), folderFacts(ubiquitous: true),
                    folderFacts(readOnly: true), folderFacts(filesystemReadOnly: true),
                    folderFacts(internalVolume: true), folderFacts(filesystemLocal: false),
                    folderFacts(directory: false), folderFacts(symbolicLink: true)]
    for facts in rejected { try check(facts.rejection != nil, "unsafe target accepted: \(facts.diagnostic)") }
}
try test("Unknown volume identity is not enough to enable external mode") {
    let allMissing = folderFacts(filesystemLocal: nil, filesystemReadOnly: nil, sameAsInternal: nil)
    let noIdentity = folderFacts(local: true, sameAsInternal: nil)
    try check(allMissing.rejection != nil && noIdentity.rejection != nil, "unknown storage was implicitly trusted")
}
try test("Real statfs facts recognize this internal test volume and its capacity") {
    let facts = ExternalFolderFacts.inspect(root)
    try check(facts.directory && facts.sameAsInternalVolume == true, "could not identify the real internal test volume")
    try check(facts.rejection != nil, "actual internal volume passed the external policy")
    try check(facts.availableBytes != nil && facts.availableBytes! >= 0, "missing real free-space measurement")
    try check(!facts.diagnostic.isEmpty, "missing rejection diagnostics")
}
try test("Direct USB-style write/read probe cleans up and preserves existing files") {
    let sentinel = root.appendingPathComponent("probe-sentinel.txt")
    let contents = Data("KEEP THIS FILE".utf8)
    try contents.write(to: sentinel)
    let before = Set(try fm.contentsOfDirectory(atPath: root.path))
    try ExternalFolderWriteProbe.verify(in: root)
    let after = Set(try fm.contentsOfDirectory(atPath: root.path))
    let data = try Data(contentsOf: sentinel)
    try check(before == after && data == contents, "probe left a file or changed existing data")
}
try test("Write/read probe refuses a directory without write permission") {
    let folder = root.appendingPathComponent("probe-read-only")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    try mustThrow { try ExternalFolderWriteProbe.verify(in: folder) }
    let contents = try fm.contentsOfDirectory(atPath: folder.path)
    try check(contents.isEmpty, "failed probe left a file")
}
print("\(passed) storage tests passed. Real iPad USB permissions, exFAT and macOS boot are NOT covered.")
