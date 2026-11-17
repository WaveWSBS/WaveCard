import Foundation
import CoreFoundation

/// Native Swift bridge to `device_helper` and `airtraffic_host` binaries.
/// Replaces all Python subprocesses with fast, direct process execution.
public final class AirliftBridge {
    public static let shared = AirliftBridge()

    private let sourcePrefix = "airlift-src-"
    private let linkPrefix = "airlift-link-"
    private let recoveredPrefix = "airlift-recovered-"
    private let airlockRoot = "/var/mobile/Media/Airlock/Book"
    // The helper bounds connect/allowed/ready/manifest/completion at
    // 30 + 30 + 120 + 60 + 60 seconds. Leave time for its final output too.
    private let airTrafficCommandTimeout: TimeInterval = 330
    private let recoveryWorkspaceLock = NSLock()
    private var activeRecoveryWorkspaces: Set<String> = []

    private init() {}

    // MARK: - Persistent Recovery Workspaces

    /// Tests use an isolated root so mock failures never leave recovery records
    /// in the real profile. Production snapshots must survive app relaunches.
    private var recoveryRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["WAVECARD_RECOVERY_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WaveCard/Recovery", isDirectory: true)
    }

    /// Only a newly created workspace is removed automatically. Existing
    /// records, including ones whose device tag cannot be read, need review.
    /// An unreadable root is returned as a blocker rather than treated as empty.
    public func pendingRecoveryDirectories(udid: String) -> [URL] {
        let fm = FileManager.default
        let root = recoveryRootURL
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [root] }
        do {
            return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { directory in
                    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                    self.recoveryWorkspaceLock.lock()
                    let active = self.activeRecoveryWorkspaces.contains(directory.resolvingSymlinksInPath().standardizedFileURL.path)
                    self.recoveryWorkspaceLock.unlock()
                    if active { return false }
                    guard let tag = try? String(contentsOf: directory.appendingPathComponent("device.udid"), encoding: .utf8),
                          !tag.isEmpty else { return true }
                    return tag == udid
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return [root]
        }
    }

    /// The device tag is written before any helper may stage device changes.
    /// Failure here must abort the operation without contacting the phone.
    private func createRecoveryWorkspace(udid: String, operation: String) throws -> URL {
        guard !udid.isEmpty else {
            throw NSError(domain: "WaveCard.Recovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create recovery workspace without a device identifier."])
        }
        let fm = FileManager.default
        let root = recoveryRootURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("wavecard-\(operation)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        recoveryWorkspaceLock.lock()
        activeRecoveryWorkspaces.insert(directory.resolvingSymlinksInPath().standardizedFileURL.path)
        recoveryWorkspaceLock.unlock()
        do {
            try Data(udid.utf8).write(to: directory.appendingPathComponent("device.udid"), options: .atomic)
        } catch {
            // This workspace has not been staged and belongs to this call.
            try? fm.removeItem(at: directory)
            releaseRecoveryWorkspace(directory)
            throw error
        }
        return directory
    }

    private func releaseRecoveryWorkspace(_ directory: URL) {
        recoveryWorkspaceLock.lock()
        activeRecoveryWorkspaces.remove(directory.resolvingSymlinksInPath().standardizedFileURL.path)
        recoveryWorkspaceLock.unlock()
    }

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
    func runCommand(_ executableURL: URL, arguments: [String], timeout: TimeInterval = 60) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let output = CommandOutput()

        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk, isError: false)
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = stderrPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk, isError: true)
            }
            group.leave()
        }

        let timedOut = group.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning {
                process.terminate()
                kill(pid_t(process.processIdentifier), SIGKILL)
            }
            _ = group.wait(timeout: .now() + 2)
        }

        let captured = output.snapshot()
        let stderr = timedOut ? "Timed out after \(timeout)s. \(captured.stderr)" : captured.stderr
        return (timedOut ? -2 : process.terminationStatus, captured.stdout, stderr)
    }

    private func runJSONCommand(_ executableURL: URL, arguments: [String], timeout: TimeInterval = 60) -> (exitCode: Int32, json: [String: Any]?) {
        let result = runCommand(executableURL, arguments: arguments, timeout: timeout)
        // Some commands (like airtraffic_host) emit progress lines then the final result
        for line in result.stdout.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
                  let data = trimmed.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if result.exitCode != 0 {
                let events = result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
                    guard let data = String(line).data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = event["type"] as? String,
                          ["atc_stage", "atc_message", "atc_message_sent", "atc_handshake_context"].contains(type) else { return nil }
                    return event
                }
                if !events.isEmpty { obj["diagnostics"] = events }
            }
            return (result.exitCode, obj)
        }
        return (result.exitCode, result.exitCode == 0 ? nil : ["error": result.stderr])
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

    private func nativeOperation(command: String, udid: String, extraArguments: [String] = [], onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Bool {
        guard let helper = AirliftBridge.findDeviceHelper() else { return false }
        var args = [command, udid]
        args.append(contentsOf: extraArguments)
        let (exitCode, json) = runJSONCommand(helper, arguments: args, timeout: 60)
        guard exitCode == 0, let json = json else {
            onFailure?(AirliftReadFailure(message: "\(command): exit \(exitCode), \(json?.description ?? "no result")"))
            return false
        }

        if let op = json["operation"] as? [String: Any], let ok = op["ok"] as? Bool {
            if !ok { onFailure?(AirliftReadFailure(message: "\(command): \(op)")) }
            return ok
        }
        let ok = (json["ok"] as? Bool) ?? false
        if !ok { onFailure?(AirliftReadFailure(message: "\(command): \(json)")) }
        return ok
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

    /// A failed transport may already have moved the source file. Cleanup is
    /// safe only when a completed helper error explicitly proves otherwise.
    /// Missing/legacy results and an outer deadline are deliberately ambiguous.
    static func failedReadIsProvenPreTransfer(exitCode: Int32, json: [String: Any]?) -> Bool {
        guard exitCode != -2,
              let json,
              let ok = json["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(), !ok.boolValue,
              let started = json["assetCompletionStarted"] as? NSNumber,
              CFGetTypeID(started) == CFBooleanGetTypeID(), !started.boolValue else { return false }
        return true
    }

    // MARK: - Airlift File Read Operations

    /// Exports a file outside Media into Media, reads it via AFC, and restores original in-place.
    /// Note: AirTraffic sync moves the file to media; read immediately writes the original back.
    public func readFile(udid: String, target: String, leaf: String, retries: Int = 2, onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Data? {
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else {
            onFailure?(AirliftReadFailure(message: "Device helper binary not found"))
            return nil
        }

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

            let tempDir: URL
            do {
                tempDir = try createRecoveryWorkspace(udid: udid, operation: "read")
            } catch {
                onFailure?(AirliftReadFailure(message: "Cannot create persistent recovery workspace at \(recoveryRootURL.path): \(error.localizedDescription)"))
                return nil
            }
            var preserveSnapshot = false
            defer {
                if !preserveSnapshot { try? FileManager.default.removeItem(at: tempDir) }
                releaseRecoveryWorkspace(tempDir)
            }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let localOut = tempDir.appendingPathComponent("recovered.bin")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)

            func cleanup() -> Bool {
                let ok = nativeOperation(command: "finish-write", udid: udid,
                    extraArguments: [source, linkDest, recovered, snapshotRoot.path], onFailure: onFailure)
                if !ok {
                    preserveSnapshot = true
                    onFailure?(AirliftReadFailure(message: "Cleanup could not be verified; snapshot retained at \(snapshotRoot.path)", requiresRecovery: true))
                }
                return ok
            }

            do {
                let dummy = "wavecard-backup-staging".data(using: .utf8)!
                let archiveData = try AirliftZip.buildArchive(target: target, payload: dummy)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                // 1. Snapshot books
                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path], onFailure: onFailure) else {
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return nil
                }

                // 2. Stage
                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ], onFailure: onFailure) else {
                    guard cleanup() else { return nil }
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    return nil
                }

                // 3. AirTraffic Sync
                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: airTrafficCommandTimeout)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    let preTransfer = Self.failedReadIsProvenPreTransfer(exitCode: atcRes.exitCode, json: atcRes.json)
                    // Only a completed manifest response can justify trying a different filename.
                    if atcRes.json?["error"] as? String != "expected assets absent from manifest" {
                        onFailure?(AirliftReadFailure(message: "AirTraffic sync: exit \(atcRes.exitCode), \(atcRes.json?.description ?? "no result (timeout or connection failure)")",
                                                      deviceUnresponsive: preTransfer))
                    }
                    guard preTransfer else {
                        // AssetCompleted is asynchronous: the file may already
                        // be recovered, or may move after the helper exits. Do
                        // not delete any staging/recovered bytes in either case.
                        preserveSnapshot = true
                        onFailure?(AirliftReadFailure(message: "Read transfer completion is unknown; device staging and recovery files retained at \(tempDir.path)", requiresRecovery: true))
                        return nil
                    }
                    _ = cleanup()
                    return nil
                }

                // 4. AFC read recovered file
                let afcRes = nativeOperation(command: "afc-read", udid: udid, extraArguments: [
                    recovered, localOut.path
                ], onFailure: onFailure)
                guard afcRes, FileManager.default.fileExists(atPath: localOut.path) else {
                    preserveSnapshot = true
                    onFailure?(AirliftReadFailure(message: "Recovered file read failed; recovery files retained at \(tempDir.path)", requiresRecovery: true))
                    return nil
                }

                let data = try Data(contentsOf: localOut)
                // AirTraffic has already moved the pass file into Media. Never
                // clean that copy up until the same bytes are back in the pkpass.
                guard !data.isEmpty else {
                    preserveSnapshot = true
                    onFailure?(AirliftReadFailure(message: "Recovered file was empty; recovery files retained at \(tempDir.path)", requiresRecovery: true))
                    return nil
                }

                let restored = writeFile(udid: udid, target: target, leaf: leaf, payload: data, retries: 3, onFailure: onFailure)
                guard restored else {
                    // Leave the recovered file in Media. finish-write would delete it.
                    preserveSnapshot = true
                    onFailure?(AirliftReadFailure(message: "Original file restoration failed; recovery files retained at \(tempDir.path)", requiresRecovery: true))
                    return nil
                }

                guard cleanup() else { return nil }
                return data
            } catch {
                preserveSnapshot = true
                onFailure?(AirliftReadFailure(message: "Local read failure: \(error.localizedDescription); recovery files retained at \(tempDir.path)", requiresRecovery: true))
                return nil
            }
        }
        return nil
    }

    // MARK: - Airlift File Write Operations

    /// Writes a single file to the device target directory.
    public func writeFile(udid: String, target: String, leaf: String, payload: Data, retries: Int = 3, onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Bool {
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else {
            onFailure?(AirliftReadFailure(message: "Device helper binary not found"))
            return false
        }

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

            let tempDir: URL
            do {
                tempDir = try createRecoveryWorkspace(udid: udid, operation: "write")
            } catch {
                onFailure?(AirliftReadFailure(message: "Cannot create persistent recovery workspace at \(recoveryRootURL.path): \(error.localizedDescription)"))
                return false
            }
            var preserveSnapshot = false
            defer {
                if !preserveSnapshot { try? FileManager.default.removeItem(at: tempDir) }
                releaseRecoveryWorkspace(tempDir)
            }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
            var attemptFailures: [AirliftReadFailure] = []
            func record(_ failure: AirliftReadFailure) { attemptFailures.append(failure) }
            func reportFailure() { attemptFailures.forEach { onFailure?($0) } }
            func cleanup(command: String = "finish-write", expectedCount: Int? = nil) -> Bool {
                var arguments = [source, linkDest, recovered, snapshotRoot.path]
                if let expectedCount { arguments.append(String(expectedCount)) }
                let ok = nativeOperation(command: command, udid: udid,
                    extraArguments: arguments, onFailure: record)
                if !ok {
                    preserveSnapshot = true
                    record(AirliftReadFailure(message: "Cleanup could not be verified; snapshot retained at \(snapshotRoot.path)", requiresRecovery: true))
                }
                return ok
            }

            do {
                let archiveData = try AirliftZip.buildArchive(target: target, payload: payload)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                // 1. Snapshot books
                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path], onFailure: record) else {
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                // 2. Stage
                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ], onFailure: record) else {
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                // 3. AirTraffic Sync
                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: airTrafficCommandTimeout)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    record(AirliftReadFailure(message: "AirTraffic sync: exit \(atcRes.exitCode), \(atcRes.json?.description ?? "no result")"))
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                // 4. Finish cleanup
                guard cleanup() else {
                    reportFailure()
                    return false
                }
                return true
            } catch {
                record(AirliftReadFailure(message: "Local staging failure: \(error.localizedDescription)"))
                if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                reportFailure()
                return false
            }
        }
        return false
    }

    /// Writes multiple files to the device target directory in a single atomic AirTraffic sync.
    public func writeFilesBatch(udid: String, target: String, files: [(leaf: String, payload: Data)], retries: Int = 3, onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Bool {
        guard !files.isEmpty else { return true }
        if files.count == 1 {
            return writeFile(udid: udid, target: target, leaf: files[0].leaf, payload: files[0].payload, retries: retries, onFailure: onFailure)
        }

        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else {
            onFailure?(AirliftReadFailure(message: "Device helper binary not found"))
            return false
        }

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

            let tempDir: URL
            do {
                tempDir = try createRecoveryWorkspace(udid: udid, operation: "write-batch")
            } catch {
                onFailure?(AirliftReadFailure(message: "Cannot create persistent recovery workspace at \(recoveryRootURL.path): \(error.localizedDescription)"))
                return false
            }
            var preserveSnapshot = false
            defer {
                if !preserveSnapshot { try? FileManager.default.removeItem(at: tempDir) }
                releaseRecoveryWorkspace(tempDir)
            }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
            var attemptFailures: [AirliftReadFailure] = []
            func record(_ failure: AirliftReadFailure) { attemptFailures.append(failure) }
            func reportFailure() { attemptFailures.forEach { onFailure?($0) } }
            func cleanup(command: String = "finish-write", expectedCount: Int? = nil) -> Bool {
                var arguments = [source, linkDest, recovered, snapshotRoot.path]
                if let expectedCount { arguments.append(String(expectedCount)) }
                let ok = nativeOperation(command: command, udid: udid,
                    extraArguments: arguments, onFailure: record)
                if !ok {
                    preserveSnapshot = true
                    record(AirliftReadFailure(message: "Cleanup could not be verified; snapshot retained at \(snapshotRoot.path)", requiresRecovery: true))
                }
                return ok
            }

            do {
                let archiveData = try AirliftZip.buildArchiveMulti(target: target, files: files)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path], onFailure: record) else {
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ], onFailure: record) else {
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: airTrafficCommandTimeout)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    record(AirliftReadFailure(message: "AirTraffic sync: exit \(atcRes.exitCode), \(atcRes.json?.description ?? "no result")"))
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                guard cleanup() else {
                    reportFailure()
                    return false
                }
                return true
            } catch {
                record(AirliftReadFailure(message: "Local staging failure: \(error.localizedDescription)"))
                if attempt < retries { usleep(UInt32(300_000 * attempt)); continue }
                reportFailure()
                return false
            }
        }
        return false
    }

    // MARK: - Pass Cache Invalidation

    /// Removes rendered card face cache entries so Wallet / SpringBoard rebuilds from .pkpass.
    public func invalidateCache(udid: String, cardHash: String, onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Bool {
        var allOk = true
        let cacheLeaves = ["FrontFace", "PlaceHolder", "Preview"]
        for ext in [".cache", ".pkcache"] {
            let cacheDir = "/var/mobile/Library/Passes/Cards/\(cardHash)\(ext)"
            var requiresRecovery = false
            let ok = removeFiles(udid: udid, target: cacheDir, leaves: cacheLeaves) { failure in
                requiresRecovery = requiresRecovery || failure.requiresRecovery
                onFailure?(failure)
            }
            allOk = allOk && ok
            // A second cache operation must not stage over an unverified preimage.
            if requiresRecovery { return false }
        }
        return allOk
    }

    /// Removes specific files through the relocated Airlift symlink by moving them into Media staging.
    public func removeFiles(udid: String, target: String, leaves: [String], retries: Int = 3, onFailure: ((AirliftReadFailure) -> Void)? = nil) -> Bool {
        guard !leaves.isEmpty else { return true }
        guard AirliftBridge.findDeviceHelper() != nil,
              let atc = AirliftBridge.findAirTrafficHost() else {
            onFailure?(AirliftReadFailure(message: "Device helper binary not found"))
            return false
        }

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

            let tempDir: URL
            do {
                tempDir = try createRecoveryWorkspace(udid: udid, operation: "remove")
            } catch {
                onFailure?(AirliftReadFailure(message: "Cannot create persistent recovery workspace at \(recoveryRootURL.path): \(error.localizedDescription)"))
                return false
            }
            var preserveSnapshot = false
            defer {
                if !preserveSnapshot { try? FileManager.default.removeItem(at: tempDir) }
                releaseRecoveryWorkspace(tempDir)
            }

            let archivePath = tempDir.appendingPathComponent("payload.zip")
            let booksPath = tempDir.appendingPathComponent("Books.plist")
            let snapshotRoot = tempDir.appendingPathComponent("books-snapshot")
            try? FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
            var attemptFailures: [AirliftReadFailure] = []
            func record(_ failure: AirliftReadFailure) { attemptFailures.append(failure) }
            func reportFailure() { attemptFailures.forEach { onFailure?($0) } }
            func cleanup(command: String = "finish-write", expectedCount: Int? = nil) -> Bool {
                var arguments = [source, linkDest, recovered, snapshotRoot.path]
                if let expectedCount { arguments.append(String(expectedCount)) }
                let ok = nativeOperation(command: command, udid: udid,
                    extraArguments: arguments, onFailure: record)
                if !ok {
                    preserveSnapshot = true
                    record(AirliftReadFailure(message: "Cleanup could not be verified; snapshot retained at \(snapshotRoot.path)", requiresRecovery: true))
                }
                return ok
            }

            do {
                let dummy = "wavecard-v2".data(using: .utf8)!
                let archiveData = try AirliftZip.buildArchive(target: target, payload: dummy)
                try archiveData.write(to: archivePath)

                let booksData = try AirliftZip.buildBooks(identifiers: identifiers)
                try booksData.write(to: booksPath)

                guard nativeOperation(command: "snapshot-books", udid: udid, extraArguments: [snapshotRoot.path], onFailure: record) else {
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                guard nativeOperation(command: "stage", udid: udid, extraArguments: [
                    source, linkDest, recovered, archivePath.path, booksPath.path, snapshotRoot.path
                ], onFailure: record) else {
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                var atcArgs = [udid]
                for (id, dst) in zip(identifiers, destinations) {
                    atcArgs.append(contentsOf: [id, dst])
                }
                let atcRes = runJSONCommand(atc, arguments: atcArgs, timeout: airTrafficCommandTimeout)
                guard atcRes.exitCode == 0, (atcRes.json?["ok"] as? Bool) == true else {
                    record(AirliftReadFailure(message: "AirTraffic sync: exit \(atcRes.exitCode), \(atcRes.json?.description ?? "no result")"))
                    guard cleanup() else {
                        reportFailure()
                        return false
                    }
                    if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                    reportFailure()
                    return false
                }

                // finish-moved-removal expects [source, linkDestination, recovered, snapshotRoot, expectedCount]
                guard cleanup(command: "finish-moved-removal", expectedCount: leaves.count) else {
                    reportFailure()
                    return false
                }
                return true
            } catch {
                record(AirliftReadFailure(message: "Local staging failure: \(error.localizedDescription)"))
                if attempt < retries { usleep(UInt32(400_000 * attempt)); continue }
                reportFailure()
                return false
            }
        }
        return false
    }
}

/// Readers may still be draining after a command deadline; protect partial diagnostics.
private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isError { stderr.append(data) } else { stdout.append(data) }
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

public struct AirliftReadFailure: LocalizedError {
    public let message: String
    public var requiresRecovery = false
    /// The AirTraffic handshake failed before any transfer started (no
    /// SyncAllowed/ReadyForSync, connection refused...). Nothing needs
    /// recovery, but the phone's sync service is unresponsive, so further
    /// reads will fail the same way until it is restarted.
    public var deviceUnresponsive = false
    public var errorDescription: String? { message }
}
