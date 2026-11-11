import Foundation
import Darwin

/// NSURL volume properties are optional, including volumeIsInternal on iPadOS.
/// Missing metadata is not evidence that a USB volume is internal or read-only.
/// A separate local filesystem provides independent positive evidence instead.
struct ExternalFolderFacts {
    let directory: Bool
    let symbolicLink: Bool
    let local: Bool?
    let internalVolume: Bool?
    let readOnly: Bool?
    let ubiquitous: Bool?
    let filesystemLocal: Bool?
    let filesystemReadOnly: Bool?
    let sameAsInternalVolume: Bool?
    let filesystemType: String?
    var availableBytes: Int64? = nil

    var rejection: String? {
        guard directory, !symbolicLink else { return "Select a regular folder on the USB drive." }
        if ubiquitous == true { return "The selected folder is cloud storage. Select a folder inside the connected USB drive." }
        if internalVolume == true || sameAsInternalVolume == true {
            return "The selected folder is on the iPad's internal volume. Open the USB drive in Browse and select a folder inside it."
        }
        if readOnly == true || filesystemReadOnly == true { return "The selected volume is read-only." }
        if local == false { return "Network storage cannot be used as the Mac's USB disk." }
        guard local == true || filesystemLocal == true else {
            return "Henge could not verify that the selected storage is local."
        }
        guard internalVolume == false || sameAsInternalVolume == false else {
            return "Henge could not distinguish the selected storage from the iPad's internal volume."
        }
        return nil
    }

    var diagnostic: String {
        func value(_ flag: Bool?) -> String { flag.map { $0 ? "yes" : "no" } ?? "unknown" }
        return "directory=\(directory), local=\(value(local)), internal=\(value(internalVolume)), "
            + "readOnly=\(value(readOnly)), fs=\(filesystemType ?? "unknown"), "
            + "fsLocal=\(value(filesystemLocal)), sameAsIPad=\(value(sameAsInternalVolume))"
    }

    static func inspect(_ url: URL) -> Self {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
            .isUbiquitousItemKey, .volumeAvailableCapacityKey])
        var item = stat()
        let haveItem = lstat(url.path, &item) == 0
        let directory = haveItem ? (item.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) : values?.isDirectory == true
        let symlink = haveItem ? (item.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) : values?.isSymbolicLink == true
        var volume = statfs()
        var home = statfs()
        let haveVolume = statfs(url.path, &volume) == 0
        let haveHome = statfs(NSHomeDirectory(), &home) == 0
        var same: Bool?
        var filesystemType: String?
        var available = (values?.volumeAvailableCapacity).map { Int64($0) }
        if haveVolume {
            filesystemType = withUnsafeBytes(of: volume.f_fstypename) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            // A zero filesystem ID cannot prove that two volumes are different.
            let id = volume.f_fsid.val, homeID = home.f_fsid.val
            if haveHome, (id.0 != 0 || id.1 != 0), (homeID.0 != 0 || homeID.1 != 0) {
                same = id.0 == homeID.0 && id.1 == homeID.1
            }
            let free = UInt64(volume.f_bavail).multipliedReportingOverflow(by: UInt64(volume.f_bsize))
            if !free.overflow, free.partialValue <= UInt64(Int64.max) {
                let measured = Int64(free.partialValue)
                available = available.map { min($0, measured) } ?? measured
            }
        }
        return Self(directory: directory, symbolicLink: symlink, local: values?.volumeIsLocal,
                    internalVolume: values?.volumeIsInternal, readOnly: values?.volumeIsReadOnly,
                    ubiquitous: values?.isUbiquitousItem,
                    filesystemLocal: haveVolume ? volume.f_flags & UInt32(MNT_LOCAL) != 0 : nil,
                    filesystemReadOnly: haveVolume ? volume.f_flags & UInt32(MNT_RDONLY) != 0 : nil,
                    sameAsInternalVolume: same, filesystemType: filesystemType, availableBytes: available)
    }
}

enum ExternalFolderWriteProbe {
    /// Probe the same direct, seekable I/O the native engine needs. Never touch an
    /// existing file: this creates one unique name exclusively and removes only it.
    static func verify(in folder: URL) throws {
        let path = folder.appendingPathComponent(".henge-write-test-\(UUID().uuidString)")
        let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(path.path) }
        let marker = Data("Henge USB access check".utf8)
        try handle.write(contentsOf: marker)
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: marker.count) == marker else {
            throw NSError(domain: "Henge.ExternalDisk", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "USB write/read verification failed."])
        }
    }
}
