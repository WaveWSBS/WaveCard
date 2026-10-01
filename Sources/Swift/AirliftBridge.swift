import Foundation

/// Native Swift bridge to `device_helper` and `airtraffic_host` binaries.
/// Replaces all Python subprocesses with fast, direct process execution.
public final class AirliftBridge {
    public static let shared = AirliftBridge()

    private let sourcePrefix = "airlift-src-"
    private let linkPrefix = "airlift-link-"
    private let recoveredPrefix = "airlift-recovered-"
    private let airlockRoot = "/var/mobile/Media/Airlock/Book"

    private init() {}

    // MARK: - Binary Resolution

    public static func findDeviceHelper() -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/device_helper"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/device_helper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/device_helper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin/device_helper")
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static func findAirTrafficHost() -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/airtraffic_host"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/airtraffic_host"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/airtraffic_host"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin/airtraffic_host")
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Process Execution Helpers

    @discardableResult
    private func runCommand(_ executableURL: URL, arguments: [String], timeout: TimeInterval = 60) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning {
                process.terminate()
                kill(pid_t(process.processIdentifier), SIGKILL)
            }
            return (-2, "", "Timed out after \(timeout)s")
        }

        process.waitUntilExit()
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdoutStr, stderrStr)
    }

    private func runJSONCommand(_ executableURL: URL, arguments: [String], timeout: TimeInterval = 60) -> (exitCode: Int32, json: [String: Any]?) {
        let result = runCommand(executableURL, arguments: arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            // Attempt to parse JSON error even on non-zero exit code
            if let data = result.stdout.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (result.exitCode, obj)
            }
            return (result.exitCode, nil)
        }

        // Some commands (like airtraffic_host) emit progress lines then the final result
        for line in result.stdout.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return (0, obj)
        }
        return (result.exitCode, nil)
    }

    // MARK: - Device Listing & Status

    public func listDevices() -> [DeviceInfo] {
        guard let helper = AirliftBridge.findDeviceHelper() else { return [] }
        // device_helper writes a JSON array. Parsing that as an object used to
        // fail and launch the helper a second time, both on the main thread.
        let result = runCommand(helper, arguments: ["list"], timeout: 4)
        guard result.exitCode == 0 else { return [] }
        return Self.parseDeviceList(result.stdout)
    }

    private static func parseDeviceList(_ stdout: String) -> [DeviceInfo] {
        func devices(from json: Any) -> [DeviceInfo]? {
            if let array = json as? [[String: Any]] {
                return array.compactMap { device(from: $0) }
            }
            if let dict = json as? [String: Any], let one = device(from: dict) {
                return [one]
            }
            return nil
        }

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let parsed = devices(from: json) {
            return parsed
        }
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let parsed = devices(from: json) else { continue }
            return parsed
        }
        return []
    }

    private static func device(from dict: [String: Any]) -> DeviceInfo? {
        guard let udid = dict["udid"] as? String, !udid.isEmpty else { return nil }
        return DeviceInfo(
            udid: udid,
            name: dict["name"] as? String,
            product: dict["product"] as? String,
            version: dict["version"] as? String,
            connected: (dict["connected"] as? Bool) ?? true
        )
    }

    // MARK: - Native Helper Dispatch

    private func nativeOperation(command: String, udid: String, extraArguments: [String] = []) -> Bool {
        guard let helper = AirliftBridge.findDeviceHelper() else { return false }
        var args = [command, udid]
        args.append(contentsOf: extraArguments)
        let (exitCode, json) = runJSONCommand(helper, arguments: args, timeout: 60)
        guard exitCode == 0, let json = json else { return false }

        if let op = json["operation"] as? [String: Any], let ok = op["ok"] as? Bool {
            return ok
        }
        return (json["ok"] as? Bool) ?? false
    }

    // MARK: - POSIX Relpath Helper

    /// Computes the relative path from basePath to targetPath (POSIX semantics).
    private func relpath(to targetPath: String, from basePath: String) -> String {
        let baseComponents = basePath.split(separator: "/").map(String.init)
        let targetComponents = targetPath.split(separator: "/").map(String.init)

        var commonPrefixLen = 0
        while commonPrefixLen < baseComponents.count &&
              commonPrefixLen < targetComponents.count &&
              baseComponents[commonPrefixLen] == targetComponents[commonPrefixLen] {
            commonPrefixLen += 1
        }

        let upCount = baseComponents.count - commonPrefixLen
        var relComponents = Array(repeating: "..", count: upCount)
        relComponents.append(contentsOf: targetComponents[commonPrefixLen...])

        return relComponents.joined(separator: "/")
    }

    // MARK: - Airlift File Read Operations

    /// Exports a file outside Media into Media, reads it via AFC, and restores original in-place.
    /// Note: AirTraffic sync moves the file to media; read immediately writes the original back.
    public func readFile(udid: String, target: String, leaf: String, retries: Int = 2) -> Data? {
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else { return nil }

        let tempBase = FileManager.default.temporaryDirectory
        for attempt in 1...max(1, retries) {
            // Token MUST be exactly 20 lowercase hex characters
            let rawHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let token = String(rawHex.prefix(20))
            let source = "\(sourcePrefix)\(token)"
            let linkDest = "\(linkPrefix)\(token)"
            let recovered = "\(recoveredPrefix)\(token)"

            let linkIdentifier = "../../\(source)/p0/p1/p2/link"
            let targetPath = (target as NSString).appendingPathComponent(leaf)
            let targetIdentifier = relpath(to: targetPath, from: airlockRoot)

            let identifiers = [linkIdentifier, targetIdentifier]
            let destinations = [linkDest, recovered]

            let tempDir = tempBase.appendingPathComponent("aircard-read-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let localOut = tempDir.appendingPathComponent("recovered.bin")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            do {
                let dummy = "aircard-backup-staging".data(using: .utf8)!
                let archiveData = try AirliftZip.buildArchive(target: target, payload: dummy)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                // 1. Snapshot books
                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path]) else {
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return nil
                }

                // 2. Stage
                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ]) else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return nil
                }

                // 3. AirTraffic Sync
                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: 120)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return nil
                }

                // 4. AFC read recovered file
                let afcRes = nativeOperation(command: "afc-read", udid: udid, extraArguments: [
                    recovered, localOut.path
                ])
                guard afcRes, FileManager.default.fileExists(atPath: localOut.path) else {
                    return nil
                }

                let data = try Data(contentsOf: localOut)

                // 5. Restore original back immediately on device!
                let restored = writeFile(udid: udid, target: target, leaf: leaf, payload: data, retries: 3)

                // 6. Finish cleanup
                let finish = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                    source, linkDest, recovered, snapshotRoot.path
                ])

                if restored && finish {
                    return data
                } else if !data.isEmpty {
                    return data
                }
            } catch {
                if attempt < retries { usleep(UInt32(400_000 * attempt)) }
            }
        }
        return nil
    }

    // MARK: - Airlift File Write Operations

    /// Writes a single file to the device target directory.
    public func writeFile(udid: String, target: String, leaf: String, payload: Data, retries: Int = 3) -> Bool {
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else { return false }

        let tempBase = FileManager.default.temporaryDirectory
        for attempt in 1...max(1, retries) {
            let rawHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let token = String(rawHex.prefix(20))
            let source = "\(sourcePrefix)\(token)"
            let linkDest = "\(linkPrefix)\(token)"
            let recovered = "\(recoveredPrefix)\(token)"

            let linkIdentifier = "../../\(source)/p0/p1/p2/link"
            let payloadIdentifier = "../../\(source)/payload"

            let targetDestination = (linkDest as NSString).appendingPathComponent(leaf)

            let identifiers = [linkIdentifier, payloadIdentifier]
            let destinations = [linkDest, targetDestination]

            let tempDir = tempBase.appendingPathComponent("aircard-write-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            do {
                let archiveData = try AirliftZip.buildArchive(target: target, payload: payload)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                // 1. Snapshot books
                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path]) else {
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                // 2. Stage
                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ]) else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                // 3. AirTraffic Sync
                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: 120)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                // 4. Finish cleanup
                let finish = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                    source, linkDest, recovered, snapshotRoot.path
                ])

                if finish { return true }
            } catch {
                if attempt < retries { usleep(UInt32(300_000 * attempt)) }
            }
        }
        return false
    }

    /// Writes multiple files to the device target directory in a single atomic AirTraffic sync.
    public func writeFilesBatch(udid: String, target: String, files: [(leaf: String, payload: Data)], retries: Int = 3) -> Bool {
        guard !files.isEmpty else { return true }
        if files.count == 1 {
            return writeFile(udid: udid, target: target, leaf: files[0].leaf, payload: files[0].payload, retries: retries)
        }

        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else { return false }

        let tempBase = FileManager.default.temporaryDirectory
        for attempt in 1...max(1, retries) {
            let rawHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let token = String(rawHex.prefix(20))
            let source = "\(sourcePrefix)\(token)"
            let linkDest = "\(linkPrefix)\(token)"
            let recovered = "\(recoveredPrefix)\(token)"

            var identifiers: [String] = ["../../\(source)/p0/p1/p2/link"]
            var destinations: [String] = [linkDest]

            for (idx, file) in files.enumerated() {
                let payloadId = "../../\(source)/payload_\(idx)"
                let targetDestination = (linkDest as NSString).appendingPathComponent(file.leaf)

                identifiers.append(payloadId)
                destinations.append(targetDestination)
            }

            let tempDir = tempBase.appendingPathComponent("aircard-write-batch-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            do {
                let archiveData = try AirliftZip.buildArchiveMulti(target: target, files: files)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path]) else {
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ]) else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: 120)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    return false
                }

                let finish = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                    source, linkDest, recovered, snapshotRoot.path
                ])

                if finish { return true }
            } catch {
                if attempt < retries { usleep(UInt32(300_000 * attempt)) }
            }
        }
        return false
    }

    // MARK: - Pass Cache Invalidation

    /// Removes rendered card face cache entries so Wallet / SpringBoard rebuilds from .pkpass.
    public func invalidateCache(udid: String, cardHash: String) -> Bool {
        var allOk = true
        let cacheLeaves = ["FrontFace", "PlaceHolder", "Preview"]
        for ext in [".cache", ".pkcache"] {
            let cacheDir = "/var/mobile/Library/Passes/Cards/\(cardHash)\(ext)"
            let ok = removeFiles(udid: udid, target: cacheDir, leaves: cacheLeaves)
            allOk = allOk && ok
        }
        return allOk
    }

    /// Removes specific files through the relocated Airlift symlink by moving them into Media staging.
    public func removeFiles(udid: String, target: String, leaves: [String], retries: Int = 3) -> Bool {
        guard !leaves.isEmpty else { return true }
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else { return false }

        let tempBase = FileManager.default.temporaryDirectory
        for attempt in 1...max(1, retries) {
            let rawHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let token = String(rawHex.prefix(20))
            let source = "\(sourcePrefix)\(token)"
            let linkDest = "\(linkPrefix)\(token)"
            let recovered = "\(recoveredPrefix)\(token)"

            let linkIdentifier = "../../\(source)/p0/p1/p2/link"
            var identifiers: [String] = [linkIdentifier]
            var destinations: [String] = [linkDest]

            for (idx, leaf) in leaves.enumerated() {
                identifiers.append("../../\(linkDest)/\(leaf)")
                destinations.append("\(source)/removed-\(idx)")
            }

            let tempDir = tempBase.appendingPathComponent("aircard-remove-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            do {
                let dummy = "aircard-v2".data(using: .utf8)!
                let archiveData = try AirliftZip.buildArchive(target: target, payload: dummy)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path]) else {
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return false
                }

                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ]) else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return false
                }

                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: 120)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    _ = nativeOperation(command: "finish-write", udid: udid, extraArguments: [
                        source, linkDest, recovered, snapshotRoot.path
                    ])
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return false
                }

                // finish-moved-removal expects [source, linkDestination, recovered, snapshotRoot, expectedCount]
                let finish = nativeOperation(command: "finish-moved-removal", udid: udid, extraArguments: [
                    source, linkDest, recovered, snapshotRoot.path, "\(leaves.count)"
                ])

                if finish { return true }
            } catch {
                if attempt < retries { usleep(UInt32(400_000 * attempt)) }
            }
        }
        return false
    }
}
