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
print("\(passed) storage tests passed. USB permissions, exFAT, iOS build and macOS boot are NOT covered.")
