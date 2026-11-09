import Foundation
import Darwin

private func externalDiskError(_ text: String) -> NSError {
    NSError(domain: "Henge.ExternalDisk", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
}

/// The bookmark is to the folder the user chose, never a hard-coded /Volumes path.
struct ExternalDiskFolder: Codable, Hashable {
    var bookmark: Data
    var name: String

    static func selected(_ url: URL) throws -> ExternalDiskFolder {
        let access = try SecurityScopedFolder(url)
        defer { withExtendedLifetime(access) {} }
        try access.checkLocalUSB()
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return ExternalDiskFolder(bookmark: data, name: url.lastPathComponent)
    }

    func open() throws -> SecurityScopedFolder {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw externalDiskError("The external folder permission has expired. Choose the same folder again in this Mac's Storage settings.") }
        let access = try SecurityScopedFolder(url)
        try access.checkLocalUSB()
        return access
    }
}

/// Balanced scope access. The engine retains its access until process exit because its workers
/// and restore threads can outlive a SwiftUI view and even the VM's stopped notification.
final class SecurityScopedFolder {
    let url: URL
    init(_ url: URL) throws {
        guard url.isFileURL, url.startAccessingSecurityScopedResource() else {
            throw externalDiskError("External drive access was refused. Connect the drive and choose its folder in Files.")
        }
        self.url = url
    }
    deinit { url.stopAccessingSecurityScopedResource() }

    func checkLocalUSB() throws {
        let v = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey])
        guard v.isDirectory == true, v.volumeIsLocal == true,
              v.volumeIsInternal == false, v.volumeIsReadOnly == false else {
            throw externalDiskError("Choose a writable folder on the connected USB drive. Cloud providers and internal storage are not supported by external mode.")
        }
    }

    func coordinate<T>(_ operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw externalDiskError("The external folder could not be coordinated.") }
        return try result.get()
    }
}

struct ExternalDiskLocation: Codable, Hashable {
    var folder: ExternalDiskFolder
    let machineID: UUID
    /// A separate random token prevents a reselected folder from silently using another disk.
    let token: UUID
    let bytes: UInt64
    var directoryName: String { "Henge-\(machineID.uuidString)" }
    static let descriptor = "external-disk.json"

    private struct Owner: Codable, Equatable {
        let format: Int
        let machineID: UUID
        let token: UUID
        let bytes: UInt64
    }
    private var owner: Owner { Owner(format: 1, machineID: machineID, token: token, bytes: bytes) }

    func createDirectory() throws -> DiskAccess {
        let scope = try folder.open()
        let disk = try scope.coordinate { root -> URL in
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            // mkdir, unlike createDirectory(withIntermediateDirectories:), refuses an existing folder.
            guard mkdir(directory.path, mode_t(0o700)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            try JSONEncoder().encode(owner).write(to: directory.appendingPathComponent("owner.json"), options: .withoutOverwriting)
            return directory.appendingPathComponent("disk.img")
        }
        return DiskAccess(url: disk, scope: scope, location: self)
    }

    func open() throws -> DiskAccess {
        let scope = try folder.open()
        let disk = scope.url.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent("disk.img")
        let access = DiskAccess(url: disk, scope: scope, location: self)
        try scope.coordinate { _ in try access.validate() }
        return access
    }

    fileprivate func validateOwner(at disk: URL) throws {
        let directory = disk.deletingLastPathComponent()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw externalDiskError("The external disk folder is not a regular folder.") }
        let marker = directory.appendingPathComponent("owner.json")
        let markerValues = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
              (markerValues.fileSize ?? Int.max) < 4096,
              try JSONDecoder().decode(Owner.self, from: Data(contentsOf: marker)) == owner else {
            throw externalDiskError("This folder does not contain this Mac's external disk. No files were changed.")
        }
    }

    fileprivate func validate(at disk: URL) throws {
        try validateOwner(at: disk)
        let diskValues = try disk.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard diskValues.isRegularFile == true, diskValues.isSymbolicLink != true,
              UInt64(diskValues.fileSize ?? 0) == bytes else {
            throw externalDiskError("The external disk is missing or has the wrong size. Reconnect its drive; do not create a replacement disk.")
        }
    }
}

final class DiskAccess {
    let url: URL
    private let scope: SecurityScopedFolder?
    private let location: ExternalDiskLocation?
    init(url: URL, scope: SecurityScopedFolder? = nil, location: ExternalDiskLocation? = nil) {
        self.url = url
        self.scope = scope
        self.location = location
    }
    func validate() throws {
        if let location { try location.validate(at: url) }
        else if !FileManager.default.fileExists(atPath: url.path) { throw externalDiskError("The disk is missing.") }
    }
    func validateOwnership() throws {
        guard let location else { throw externalDiskError("There is no external disk identity.") }
        try location.validateOwner(at: url)
    }
}

#if !HENGE_STORAGE_PROBE
extension VirtualMac {
    func openDisk() throws -> DiskAccess {
        if let externalDisk { return try externalDisk.open() }
        let access = DiskAccess(url: disk)
        try access.validate()
        return access
    }
}

@MainActor
enum ExternalDiskRuntime {
    // Henge supports one native VM per process. Do not release the scope merely because the UI closes.
    private static var held: [DiskAccess] = []
    static func retain(_ access: DiskAccess) { held.append(access) }
    static func tune(for mac: VirtualMac) {
        if mac.externalDisk != nil {
            setenv("HV_EXTERNAL_DISK", "1", 1)
            setenv("HV_WRITE_CACHE", "0", 1)
        } else { unsetenv("HV_EXTERNAL_DISK") }
    }
}
#endif
