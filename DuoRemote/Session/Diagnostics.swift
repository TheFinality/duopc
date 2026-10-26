import CryptoKit
import Foundation
import MetricKit

/// Saves MetricKit crash/hang diagnostics (delivered by iOS on the next launch after a crash or
/// hang) as JSON files, so they can be shared from the app instead of waiting for TestFlight.
nonisolated final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    static var folder: URL {
        let url = URL.documentsDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Also save anything iOS has already queued for us.
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            var kinds: [String] = []
            if !(p.crashDiagnostics ?? []).isEmpty { kinds.append("crash") }
            if !(p.hangDiagnostics ?? []).isEmpty { kinds.append("hang") }
            if kinds.isEmpty { kinds.append("other") }
            let stamp = ISO8601DateFormatter().string(from: p.timeStampEnd).replacingOccurrences(of: ":", with: "-")
            let url = Self.folder.appending(path: "\(stamp)-\(kinds.joined(separator: "+")).json")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? p.jsonRepresentation().write(to: url)
        }
    }

    /// Saved reports, newest first.
    static func reports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Checks the installed app's code against its own signature, page by page, as iOS does when it
/// first runs each page. Sideloading has produced installs with a damaged page, which iOS only
/// kills the app for once that page's code runs (e.g. on connecting), so this finds it at launch.
nonisolated enum CodeIntegrity {
    /// File offsets of code pages whose SHA-256 doesn't match the signature: empty when intact,
    /// nil when there's nothing to check (not a 64-bit Mach-O, or no SHA-256 code directory).
    static func damagedPages(in data: Data) -> [Int]? {
        func u32(_ offset: Int, bigEndian: Bool) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return Int(bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw))
        }
        func byte(_ offset: Int) -> Int? { offset < data.count ? Int(data[data.startIndex + offset]) : nil }

        guard u32(0, bigEndian: false) == 0xFEED_FACF, let commands = u32(16, bigEndian: false) else { return nil }
        var offset = 32
        var signature: (offset: Int, size: Int)?
        for _ in 0..<commands {
            guard let command = u32(offset, bigEndian: false), let size = u32(offset + 4, bigEndian: false), size > 0 else { return nil }
            if command == 0x1D, let dataOffset = u32(offset + 8, bigEndian: false), let dataSize = u32(offset + 12, bigEndian: false) {
                signature = (dataOffset, dataSize)
            }
            offset += size
        }
        guard let signature, signature.offset + signature.size <= data.count,
              let blobCount = u32(signature.offset + 8, bigEndian: true) else { return nil }

        for index in 0..<blobCount {
            guard let blobOffset = u32(signature.offset + 16 + 8 * index, bigEndian: true) else { return nil }
            let directory = signature.offset + blobOffset
            guard u32(directory, bigEndian: true) == 0xFADE_0C02,
                  let hashOffset = u32(directory + 16, bigEndian: true),
                  let codeSlots = u32(directory + 28, bigEndian: true),
                  let codeLimit = u32(directory + 32, bigEndian: true),
                  byte(directory + 36) == 32, byte(directory + 37) == 2,          // SHA-256
                  let pageShift = byte(directory + 39), pageShift > 0,
                  codeLimit <= data.count else { continue }
            let pageSize = 1 << pageShift
            let hashes = directory + hashOffset
            guard hashes + codeSlots * 32 <= data.count else { return nil }
            var damaged: [Int] = []
            for slot in 0..<codeSlots {
                let start = slot * pageSize
                let end = min(start + pageSize, codeLimit)
                guard start < end else { break }
                let actual = Data(SHA256.hash(data: data[(data.startIndex + start)..<(data.startIndex + end)]))
                let expected = data[(data.startIndex + hashes + slot * 32)..<(data.startIndex + hashes + slot * 32 + 32)]
                if actual != expected { damaged.append(start) }
            }
            return damaged
        }
        return nil
    }

    /// Damaged page offsets in this app's own executable, read from disk.
    static func checkInstalledApp() -> [Int]? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return damagedPages(in: data)
    }
}
