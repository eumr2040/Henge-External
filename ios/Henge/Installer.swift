import Foundation
import UIKit

/// A macOS restore image Apple publishes for virtual Macs (VirtualMac2,1).
struct MacOSRelease: Identifiable, Hashable {
    let id: String        // build
    let name: String
    let url: URL
    let bytes: Int64
    let note: String

    /// The builds offered, newest last. Apple's catalog (mesu.apple.com) only lists the newest;
    /// these are the same images from Apple's CDN, and Apple still signs them for virtual Macs.
    static let all: [MacOSRelease] = [
        MacOSRelease(id: "24G90", name: "macOS Sequoia 15.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
                     bytes: 16_035 << 20, note: "Recommended: the version Henge is tested with."),
        MacOSRelease(id: "25G83", name: "macOS Tahoe 26.6.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
                     bytes: 18_856 << 20, note: "Not tested with Henge yet."),
        MacOSRelease(id: "26B123", name: "macOS 27.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw")!,
                     bytes: 24_409 << 20, note: "The newest. Not tested with Henge yet."),
    ]
}

/// Downloads a restore image and installs it on a new virtual Mac, on the
/// iPhone: the machine boots its ROM in DFU mode and the restore runs over its
/// USB port, as Virtualization.framework's installer does on a Mac.
@MainActor
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    enum Phase: Equatable {
        case idle
        case downloading
        case preparing
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var step: Int = 0
    @Published private(set) var stepProgress: Double = 0
    @Published private(set) var machineName = ""
    @Published private(set) var diskPrepared: Double = 0

    private var session: URLSession?
    /* Background time, so a moment out of the foreground (a notification, iPhone Mirroring reconnecting)
       does not suspend the restore at once; iOS gives about 30 s. */
    private var grace = UIBackgroundTaskIdentifier.invalid
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    nonisolated(unsafe) private var downloadTarget: URL? // set before the task starts, read by the delegate
    private var lastResumeData: Data?

    var busy: Bool {
        switch phase {
        case .downloading, .preparing, .installing: return true
        default: return false
        }
    }

    nonisolated static var imageDirectory: URL { Machines.root.appendingPathComponent("Restore images", isDirectory: true) }
    nonisolated static func imagePath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw") }

    /// The size of the image on this iPhone, if a whole one is there (the listed sizes are rounded).
    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func deleteImage(_ r: MacOSRelease) { try? FileManager.default.removeItem(at: imagePath(r)) }

    /// Free space an install takes: the new Mac's disk, and the download if it is not here yet.
    static func spaceNeeded(_ r: MacOSRelease, external: Bool = false, ramMB: Int = 2048) -> Int64 {
        InstallSpace.internalBytes(imageBytes: r.bytes, haveImage: haveImage(r), external: external, ramMB: ramMB)
    }

    static func externalSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        InstallSpace.externalBytes(imageBytes: r.bytes, haveImage: haveImage(r))
    }

    func reset() { if !busy { phase = .idle } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    func start(_ release: MacOSRelease, name: String, ramMB: Int, cpus: Int, keepImage: Bool,
               externalFolder: ExternalDiskFolder? = nil) {
        guard !busy else { return }
        // Set synchronously, before the Task starts; a second tap must not start a second install.
        phase = .preparing
        diskPrepared = 0
        machineName = name
        UIApplication.shared.isIdleTimerDisabled = true // the screen locking would suspend the download and the restore
        grace = UIApplication.shared.beginBackgroundTask(withName: "Henge install") {
            MainActor.assumeIsolated { Installer.shared.endGrace() }
        }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            var made: VirtualMac?
            do {
                guard JITBootstrap.ready else { throw message("Turn on JIT before installing.") }
                guard henge_vm_state() == 0 else { throw message("Quit and reopen Henge before installing another Mac.") }
                let workspace = try externalFolder.map { try ExternalInstallWorkspace(folder: $0) }
                try checkSpace(release, workspace: workspace, ramMB: ramMB)
                let rom = try await BootROM.file() // before the long download, so a problem shows up at once
                HengeLog.log("install", "boot ROM ready")
                let ipsw = try await download(release, workspace: workspace)
                phase = .preparing
                var mac = try await prepare(name: name, ramMB: ramMB, rom: rom, externalFolder: externalFolder)
                mac.osName = release.name
                if mac.externalDisk != nil {
                    try JSONEncoder().encode(mac).write(to: mac.directory.appendingPathComponent("pending-machine.json"), options: .atomic)
                }
                made = mac
                phase = .installing
                try await install(mac, ipsw: ipsw, cpus: cpus, workspace: workspace)
                if !keepImage {
                    if let workspace, ipsw != Self.imagePath(release) {
                        try? workspace.image(id: release.id, source: release.url).removeCompletedImage()
                    } else { try? FileManager.default.removeItem(at: ipsw) }
                }
                HengeLog.log("install", "\(name): installed \(release.name)")
                phase = .done("\(release.name) is installed on \(name). Quit Henge (swipe it away) and open it again, then tap Start.")
            } catch {
                HengeLog.log("install", "failed: \(error.localizedDescription)")
                if made != nil, henge_vm_state() == 1 { henge_vm_stop() }
                // A half-installed Mac is no use, and its disk can be many gigabytes. The download stays.
                if let made, made.externalDisk == nil, henge_vm_state() != 1 { try? FileManager.default.removeItem(at: made.directory) }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func checkSpace(_ r: MacOSRelease, workspace: ExternalInstallWorkspace?, ramMB: Int) throws {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Self.spaceNeeded(r, external: workspace != nil, ramMB: ramMB)
        if let workspace {
            try workspace.validate()
            let cachedSize = try workspace.image(id: r.id, source: r.url).completeSize
            let haveImage = Self.haveImage(r) || cachedSize != nil
            let externalNeeded = InstallSpace.externalBytes(imageBytes: r.bytes, haveImage: haveImage)
            let facts = ExternalFolderFacts.inspect(workspace.directory)
            guard let available = facts.availableBytes else {
                throw message("Cannot measure USB free space. Installation was not started. [\(facts.diagnostic)]")
            }
            guard available >= externalNeeded else {
                throw message("External storage needs about \(ByteText.string(UInt64(externalNeeded))) free for the 64 GiB disk, restore download, extracted files and reserve.")
            }
            guard free > 0 else { throw message("Cannot measure internal free space. Installation was not started.") }
        }
        if free > 0 && free < needed {
            throw message("This install needs about \(ByteText.string(UInt64(needed))) free; this \(Device.name) has \(ByteText.string(UInt64(free))).")
        }
    }

    // MARK: Download

    private func download(_ r: MacOSRelease, workspace: ExternalInstallWorkspace?) async throws -> URL {
        if let workspace {
            // Existing internal images can be read in place, without copying 16+ GB to USB.
            if Self.haveImage(r) { return Self.imagePath(r) }
            return try await downloadToUSB(r, workspace: workspace)
        }
        let dest = Self.imagePath(r)
        try FileManager.default.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Self.imageDirectory)
        if Self.haveImage(r) {
            HengeLog.log("install", "using the downloaded \(r.name)")
            return dest
        }
        phase = .downloading
        received = 0
        expected = r.bytes
        downloadTarget = dest
        HengeLog.log("install", "downloading \(r.url.absoluteString)")
        for attempt in 1...20 {
            do {
                return try await downloadOnce(r.url)
            } catch let error as URLError where error.code != .cancelled && attempt < 20 {
                lastResumeData = error.downloadTaskResumeData ?? lastResumeData
                HengeLog.log("install", "download interrupted (\(error.localizedDescription)); resuming")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw message("The download kept failing.")
    }

    private func downloadToUSB(_ r: MacOSRelease, workspace: ExternalInstallWorkspace) async throws -> URL {
        let store = try workspace.image(id: r.id, source: r.url)
        if let size = store.completeSize {
            guard size > r.bytes / 2 else { throw message("The cached USB restore image is much smaller than expected. It was not used.") }
            received = size
            expected = size
            return store.url
        }
        phase = .downloading
        received = 0
        expected = r.bytes
        HengeLog.log("install", "streaming restore image directly to USB: \(r.id)")
        for attempt in 1...20 {
            try workspace.validate()
            do {
                let downloader = RestoreImageDownload(store: store) { received, expected in
                    Task { @MainActor in
                        Installer.shared.received = received
                        Installer.shared.expected = expected
                    }
                }
                let url = try await downloader.start()
                try workspace.validate()
                guard (store.completeSize ?? 0) > r.bytes / 2 else {
                    throw message("The USB restore download is much smaller than expected. It was not used.")
                }
                return url
            } catch let error as URLError where error.code != .cancelled && attempt < 20 {
                HengeLog.log("install", "USB download interrupted (\(error.localizedDescription)); retrying its partial file")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw message("The USB download kept failing. Its partial file was kept.")
    }

    private func downloadOnce(_ url: URL) async throws -> URL {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 48 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            downloadContinuation = c
            let task = lastResumeData.map { s.downloadTask(withResumeData: $0) } ?? s.downloadTask(with: url)
            lastResumeData = nil
            task.resume()
        }
    }

    // MARK: The new machine

    private func prepare(name: String, ramMB: Int, rom: URL, externalFolder: ExternalDiskFolder?) async throws -> VirtualMac {
        // A new machine identity, as VZMacMachineIdentifier makes one: a random ECID.
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        var mac = VirtualMac(name: name, ecid: ecid, seed: 0, ramMB: ramMB, diskBytes: 64 << 30)
        if let externalFolder {
            mac.externalDisk = ExternalDiskLocation(folder: externalFolder, machineID: mac.id, token: UUID(), bytes: UInt64(64) << 30)
        }
        (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
        let fm = FileManager.default
        try fm.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Machines.root)
        try? fm.removeItem(at: mac.rom)
        try fm.copyItem(at: rom, to: mac.rom)
        if let external = mac.externalDisk {
            // Persist before slow USB writes so a crash cannot make cleanup discard the association.
            try JSONEncoder().encode(external).write(to: mac.directory.appendingPathComponent(ExternalDiskLocation.descriptor), options: .atomic)
            let location = external
            let worker = Task.detached(priority: .utility) {
                let access = try location.createDirectory()
                defer { withExtendedLifetime(access) {} }
                try FullDiskWriter.create(at: access.url, bytes: location.bytes, cancelled: { Task.isCancelled }) { done, total in
                    Task { @MainActor in Installer.shared.diskPrepared = Double(done) / Double(total) }
                }
                try access.validate()
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        } else {
            guard fm.createFile(atPath: mac.disk.path, contents: nil) else { throw message("Cannot create the disk.") }
            let h = try FileHandle(forWritingTo: mac.disk)
            try h.truncate(atOffset: UInt64(64) << 30) // internal APFS sparse disk
            try h.close()
        }
        guard henge_make_aux(mac.aux.path) == 0 else { throw message("Cannot create the auxiliary storage.") }
        let info: [String: Any] = ["name": name, "ecid": ecid, "seed": 0, "ramMB": ramMB]
        try JSONSerialization.data(withJSONObject: info).write(to: mac.directory.appendingPathComponent("machine.json"))
        mac.diskBytes = 64 << 30
        HengeLog.log("install", "new machine \(name): ECID \(ecid), 64 GB disk")
        return mac
    }

    // MARK: The restore

    private func install(_ mac: VirtualMac, ipsw: URL, cpus: Int, workspace: ExternalInstallWorkspace?) async throws {
        guard JITBootstrap.ready else { throw message("Turn on JIT first: the installer runs the Mac's own restore system, which needs it.") }
        let diskAccess = try mac.openDisk()
        ExternalDiskRuntime.retain(diskAccess)
        ExternalDiskRuntime.tune(for: mac)
        if let workspace { ExternalDiskRuntime.retain(workspace) }
        // The restore needs 2 GB, whatever the Mac is set to use afterwards, and gets at most 4 GB: the restore system
        // caches the ~15 GB it writes, so it fills all the memory it is given, and 10 GB of a 12 GB iPhone's RAM in use
        // (it is outside Henge's footprint, so iOS does not stop it) stalls the whole phone two thirds of the way through.
        var restoring = mac
        restoring.ramMB = min(max(mac.ramMB, 2048), 4096)
        let ram = GuestMemory.prepare(restoring)
        guard ram >= 2048 else { throw message("Installing needs a few more GB of free storage for the Mac's memory.") }
        setenv("HV_WRITE_CACHE", "0", 1) // the ~15 GB the restore writes goes straight to storage (host/disk.c); this process runs no other Mac
        let work: URL
        if let workspace {
            work = try workspace.makeRestoreDirectory(for: mac.id)
            HengeLog.log("install", "restore extraction cache is on USB")
        } else {
            work = mac.directory.appendingPathComponent("restore", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(mac.rom.path, diskAccess.url.path, mac.aux.path, mac.ecid, ipsw.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if mac.externalDisk != nil {
                do { try diskAccess.validate(); try workspace?.validate() }
                catch {
                    henge_vm_stop()
                    throw message("External disk access was lost. The VM was asked to stop. Reconnect the drive and inspect the log; disk integrity is not guaranteed.")
                }
            }
            step = Int(henge_install_step())
            stepProgress = henge_install_progress()
            if step == 100 { break }
            if step == 101 { throw message("The restore failed. The log (Settings, or Documents/henge.log) says why.") }
            if henge_vm_state() == 2 && step < 100 {
                // The restore ends with the machine restarting, and idevicerestore finishes a
                // little after; a stop with no result after that is a failure.
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("The machine stopped during the restore (\(String(cString: henge_vm_exit_reason()))).")
            }
        }
        // In the list before anything else: stopping the restore system can take a while, and if Henge is
        // stopped meanwhile (the phone locked) a finished Mac must not be left on the disk unlisted.
        try? (mac.osName ?? "").write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
        Machines.shared.add(mac)
        HengeLog.log("install", "\(mac.name): restore finished, added to the Macs")
        if henge_vm_state() == 1 { henge_vm_stop() }
        if let workspace { try? workspace.removeRestoreDirectory(work) }
        else { try? FileManager.default.removeItem(at: work) }
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "Finding the Mac"
        case 1: return "Starting the installer"
        case 2: return "Writing macOS"
        case 3: return "Checking macOS"
        case 4: return "Installing firmware"
        case 6, 7: return "Installing system files"
        default: return "Installing"
        }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension Installer: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.received = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.expected = totalBytesExpectedToWrite }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                                expectedTotalBytes: Int64) {
        Task { @MainActor in self.received = fileOffset }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone when this returns: move it now, on this thread.
        let target = self.downloadTarget
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard let target, status == 200 || status == 206 else {
                throw NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple's server answered \(status)."])
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            Task { @MainActor in
                self.downloadContinuation?.resume(returning: target)
                self.downloadContinuation = nil
            }
        } catch {
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: error)
                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }
}
