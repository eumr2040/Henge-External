import Foundation

enum InstallSpace {
    static func internalBytes(imageBytes: Int64, haveImage: Bool, external: Bool, ramMB: Int) -> Int64 {
        if external {
            // Guest-memory fallback stays on fast internal storage; leave 2 GiB for iPadOS,
            // the ROM/identity and small framework temporary files. Large restore files use USB.
            return Int64(max(ramMB, 2048)) * (1 << 20) + (2 << 30)
        }
        return (haveImage ? 0 : imageBytes) + (24 << 30)
    }

    static func externalBytes(imageBytes: Int64, haveImage: Bool) -> Int64 {
        // Fully allocated 64 GiB guest disk + IPSW + a conservative extraction allowance.
        // This is a preflight estimate, not a bound on every future restore image.
        (64 << 30) + (haveImage ? 0 : imageBytes) + imageBytes * 2 + (2 << 30)
    }
}
