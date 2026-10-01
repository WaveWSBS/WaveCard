import AppKit
import Foundation

public struct CardBackup: Identifiable, Codable, Hashable {
    public var id: String { cardHash }
    public let cardHash: String
    public var label: String
    public let date: Date
    public let deviceModel: String?
    public let iosVersion: String?
    public let files: [String]
    public let folderPath: String

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public var thumbnailURL: URL? {
        let base = URL(fileURLWithPath: folderPath)
        for name in ["cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png", "cardBackgroundCombined.png"] {
            let candidate = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(cardHash)
    }

    public static func == (lhs: CardBackup, rhs: CardBackup) -> Bool {
        lhs.cardHash == rhs.cardHash
    }
}

/// Manages local Apple Wallet pass backups and 1-click restore.
public final class CardBackupManager {
    public static let shared = CardBackupManager()
    private let backupsRoot: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.backupsRoot = docs.appendingPathComponent("AirCard/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
    }

    public var backupsDirectory: URL { backupsRoot }
    public var backupsRootURL: URL { backupsRoot }

    public func backupFolder(for cardHash: String) -> URL {
        backupsRoot.appendingPathComponent(cardHash, isDirectory: true)
    }

    public func hasBackup(for cardHash: String) -> Bool {
        let folder = backupFolder(for: cardHash)
        let manifest = folder.appendingPathComponent("backup.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    public func listBackups() -> [CardBackup] {
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [CardBackup] = []
        for dir in subdirs {
            let manifestURL = dir.appendingPathComponent("backup.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let backup = try? JSONDecoder().decode(CardBackup.self, from: data) else {
                continue
            }
            results.append(backup)
        }
        return results.sorted { $0.date > $1.date }
    }

    public func revealBackupInFinder(cardHash: String) {
        let folder = backupFolder(for: cardHash)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    public func backupCard(
        udid: String,
        cardHash: String,
        label: String,
        device: DeviceInfo?,
        onLog: @escaping (String) -> Void
    ) async -> Bool {
        let pkpassDir = "/var/mobile/Library/Passes/Cards/\(cardHash).pkpass"
        let folder = backupFolder(for: cardHash)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let targetLeaves = [
            "cardBackgroundCombined@3x.png",
            "cardBackgroundCombined@2x.png",
            "cardBackgroundCombined.png",
            "cardBackgroundCombined.pdf",
            "pass.json"
        ]

        var savedFiles: [String] = []
        for leaf in targetLeaves {
            onLog("Attempting to backup \(leaf)...")
            if let data = AirliftBridge.shared.readFile(udid: udid, target: pkpassDir, leaf: leaf, retries: 2) {
                let localOut = folder.appendingPathComponent(leaf)
                do {
                    try data.write(to: localOut)
                    savedFiles.append(leaf)
                    onLog("✓ Backed up \(leaf) (\(data.count) bytes)")
                } catch {
                    onLog("Error saving \(leaf): \(error.localizedDescription)")
                }
            }
        }

        guard !savedFiles.isEmpty else {
            onLog("Failed: No pass files could be read from device.")
            try? FileManager.default.removeItem(at: folder)
            return false
        }

        let backup = CardBackup(
            cardHash: cardHash,
            label: label,
            date: Date(),
            deviceModel: device?.product,
            iosVersion: device?.version,
            files: savedFiles,
            folderPath: folder.path
        )

        let manifestURL = folder.appendingPathComponent("backup.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(backup) {
            try? data.write(to: manifestURL)
        }

        onLog("✓ Successfully created backup with \(savedFiles.count) file(s)")
        return true
    }

    public func restoreCard(
        udid: String,
        cardHash: String,
        onLog: @escaping (String) -> Void
    ) async -> Bool {
        let folder = backupFolder(for: cardHash)
        guard hasBackup(for: cardHash) else {
            onLog("No backup exists for card \(cardHash)")
            return false
        }

        let manifestURL = folder.appendingPathComponent("backup.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let backup = try? JSONDecoder().decode(CardBackup.self, from: data) else {
            onLog("Backup manifest is corrupted")
            return false
        }

        var filesToRestore: [(leaf: String, payload: Data)] = []
        for filename in backup.files {
            let fileURL = folder.appendingPathComponent(filename)
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            filesToRestore.append((leaf: filename, payload: fileData))
        }

        guard !filesToRestore.isEmpty else {
            onLog("No files found to restore")
            return false
        }

        let pkpassDir = "/var/mobile/Library/Passes/Cards/\(cardHash).pkpass"
        onLog("Restoring \(filesToRestore.count) file(s) to device...")

        let writeOk = AirliftBridge.shared.writeFilesBatch(
            udid: udid,
            target: pkpassDir,
            files: filesToRestore,
            retries: 3
        )

        guard writeOk else {
            onLog("Failed to write restored files to device")
            return false
        }

        onLog("Invalidating Passbook cache...")
        _ = AirliftBridge.shared.invalidateCache(udid: udid, cardHash: cardHash)
        onLog("✓ Restore complete for \(backup.label)!")
        return true
    }

    public func deleteBackup(cardHash: String) {
        let folder = backupFolder(for: cardHash)
        try? FileManager.default.removeItem(at: folder)
    }
}
