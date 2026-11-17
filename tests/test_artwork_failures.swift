import Foundation

@main
struct ArtworkFailuresTest {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wavecard-failures-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("build")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let previousDirectory = fm.currentDirectoryPath
        defer {
            fm.changeCurrentDirectoryPath(previousDirectory)
            try? fm.removeItem(at: root)
        }
        fm.changeCurrentDirectoryPath(root.path)
        let log = root.appendingPathComponent("calls")
        let recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)
        setenv("WAVECARD_RECOVERY_ROOT", recoveryRoot.path, 1)
        setenv("WAVECARD_TEST_LOG", log.path, 1)
        defer {
            unsetenv("WAVECARD_TEST_LOG")
            unsetenv("WAVECARD_TEST_MODE")
            unsetenv("WAVECARD_RECOVERY_ROOT")
        }

        func script(_ name: String, _ content: String) throws {
            let url = bin.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script("device_helper", """
        #!/bin/sh
        printf '%s\\n' "$1" >> "$WAVECARD_TEST_LOG"
        if [ "$1" = "finish-write" ] && [ "$WAVECARD_TEST_MODE" = "cleanup-failure" ]; then
          printf '%s\\n' '{"operation":{"ok":false,"booksPreimageRestored":false}}'
          exit 2
        fi
        printf '%s\\n' '{"operation":{"ok":true}}'
        """)
        try script("airtraffic_host", """
        #!/bin/sh
        printf '%s\\n' 'sync' >> "$WAVECARD_TEST_LOG"
        printf '%s\\n' '{"type":"atc_stage","stage":"wait-SyncAllowed"}'
        printf '%s\\n' '{"type":"atc_message","stage":"wait-SyncAllowed","message":"Ping"}'
        if [ "$WAVECARD_TEST_MODE" = "absent" ]; then
          printf '%s\\n' '{"ok":false,"error":"expected assets absent from manifest","assetCompletionStarted":false}'
          exit 5
        fi
        printf '%s\\n' '{"ok":false,"error":"timeout","stage":"wait-SyncAllowed","assetCompletionStarted":false}'
        exit 124
        """)
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok" : "not ok") - \(message)")
            if !condition { failures += 1 }
        }
        func reset(_ mode: String) throws {
            setenv("WAVECARD_TEST_MODE", mode, 1)
            try Data().write(to: log)
        }
        func syncCount() throws -> Int {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0 == "sync" }.count
        }
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try reset("sync-failure")
        do {
            _ = try await CardAssetManager.shared.fetchOriginalArtworkData(udid: "mock", cardHash: hash)
            expect(false, "transport failure must throw")
        } catch {
            expect(error.localizedDescription.contains("wait-SyncAllowed"), "nonzero exit preserves the last sync stage")
            expect(error.localizedDescription.contains("Ping"), "nonzero exit preserves preceding protocol messages")
            expect((error as? AirliftReadFailure)?.requiresRecovery == false, "successful cleanup does not request recovery")
        }
        expect(try syncCount() == 1, "transport failure stops remaining filenames")
        let operations = try String(contentsOf: log, encoding: .utf8)
        expect(operations.contains("finish-write"), "transport failure attempts cleanup")

        try reset("absent")
        let data = try await CardAssetManager.shared.fetchOriginalArtworkData(udid: "mock", cardHash: hash)
        expect(try data == nil && syncCount() == 7, "a completed unavailable response permits all filename fallbacks")

        func readDirectories() throws -> Set<URL> {
            Set(try fm.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("wavecard-read-") })
        }
        let before = try readDirectories()
        try reset("cleanup-failure")
        do {
            _ = try await CardAssetManager.shared.fetchOriginalArtworkData(udid: "mock", cardHash: hash)
            expect(false, "unverified cleanup must throw")
        } catch {
            expect((error as? AirliftReadFailure)?.requiresRecovery == true, "unverified cleanup requests a queue pause")
            expect(error.localizedDescription.contains("snapshot retained"), "cleanup failure reports the recovery location")
        }
        expect(try syncCount() == 1, "cleanup failure stops filename fallbacks")
        let retained = try readDirectories().subtracting(before)
        expect(retained.count == 1, "unverified cleanup retains the local recovery directory")
        for directory in retained { try fm.removeItem(at: directory) }

        // A deadline must preserve output already printed by a blocked helper.
        let output = AirliftBridge.shared.runCommand(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '{\"stage\":\"wait-SyncAllowed\"}'; exec sleep 2"], timeout: 0.1)
        expect(output.exitCode == -2 && output.stdout.contains("wait-SyncAllowed"), "timeout preserves partial diagnostics")
        // A descendant may keep stdout open after the timed-out parent dies.
        // Low-volume diagnostics must already have been captured in that case.
        let inherited = AirliftBridge.shared.runCommand(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & printf 'partial-before-timeout\\n'; wait"], timeout: 0.1)
        expect(inherited.exitCode == -2 && inherited.stdout.contains("partial-before-timeout"),
               "timeout retains low-volume output even while a descendant keeps the pipe open")
        // A command can close its pipes before it exits; its lifetime still needs a deadline.
        let started = Date()
        let closed = AirliftBridge.shared.runCommand(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&- 2>&-; exec sleep 2"], timeout: 0.1)
        expect(closed.exitCode == -2 && Date().timeIntervalSince(started) < 1.5, "deadline also bounds processes with closed output pipes")
        if failures > 0 { exit(1) }
    }
}
