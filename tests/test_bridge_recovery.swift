import Foundation
import AppKit

/// Every helper here is a local script. These tests never contact a device.
@main
struct BridgeRecoveryTest {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--pending" {
            let paths = AirliftBridge.shared.pendingRecoveryDirectories(udid: CommandLine.arguments[2]).map(\.path)
            let json = try JSONSerialization.data(withJSONObject: paths)
            print(String(decoding: json, as: UTF8.self))
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wavecard-recovery-test-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("build")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let previousDirectory = fm.currentDirectoryPath
        let calls = root.appendingPathComponent("calls")
        let snapshots = root.appendingPathComponent("snapshots")
        let syncs = root.appendingPathComponent("syncs")
        let ready = root.appendingPathComponent("ready")
        let recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)
        let device = root.appendingPathComponent("mock-device", isDirectory: true)
        try fm.createDirectory(at: device, withIntermediateDirectories: true)
        defer {
            fm.changeCurrentDirectoryPath(previousDirectory)
            for key in ["WAVECARD_RECOVERY_MODE", "WAVECARD_RECOVERY_CALLS", "WAVECARD_RECOVERY_SNAPSHOTS", "WAVECARD_RECOVERY_SYNCS", "WAVECARD_RECOVERY_ROOT", "WAVECARD_RECOVERY_READY", "WAVECARD_RECOVERY_DEVICE"] {
                unsetenv(key)
            }
            try? fm.removeItem(at: root)
        }
        fm.changeCurrentDirectoryPath(root.path)
        setenv("WAVECARD_RECOVERY_CALLS", calls.path, 1)
        setenv("WAVECARD_RECOVERY_SNAPSHOTS", snapshots.path, 1)
        setenv("WAVECARD_RECOVERY_SYNCS", syncs.path, 1)
        setenv("WAVECARD_RECOVERY_ROOT", recoveryRoot.path, 1)
        setenv("WAVECARD_RECOVERY_READY", ready.path, 1)
        setenv("WAVECARD_RECOVERY_DEVICE", device.path, 1)
        func script(_ name: String, _ text: String) throws {
            let url = bin.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script("device_helper", """
        #!/bin/sh
        printf '%s\\n' "$1" >> "$WAVECARD_RECOVERY_CALLS"
        if [ "$1" = snapshot-books ]; then
          if [ "$(cat "$3/../device.udid")" != mock ]; then
            printf '%s\\n' '{"operation":{"ok":false,"error":"device tag missing before snapshot"}}'
            exit 9
          fi
          printf '%s\\n' "$3" >> "$WAVECARD_RECOVERY_SNAPSHOTS"
          printf fixture > "$3/fixture"
          if [ "$WAVECARD_RECOVERY_MODE" = hold-snapshot ]; then
            touch "$WAVECARD_RECOVERY_READY"
            sleep 1
          fi
        fi
        if [ "$1" = afc-read ]; then printf original > "$4"; fi
        # The real finish-write deletes recovered before verifying Books state.
        # A failed read must never reach this cleanup while transfer is unknown.
        if [ "$1" = finish-write ]; then rm -f "$WAVECARD_RECOVERY_DEVICE/$5"; fi
        case "$WAVECARD_RECOVERY_MODE:$1" in
          stage-cleanup-failure:stage|stage-cleanup-failure:finish-write|sync-cleanup-failure:finish-write|cleanup-failure:finish-write|restore-cleanup-failure:finish-write|cleanup-failure:finish-moved-removal|sync-cleanup-failure:finish-moved-removal|restore-cache-failure:finish-moved-removal)
            printf '%s\\n' '{"operation":{"ok":false,"booksPreimageRestored":false}}'
            exit 2;;
        esac
        printf '%s\\n' '{"operation":{"ok":true}}'
        """)
        try script("airtraffic_host", """
        #!/bin/sh
        printf '%s\\n' sync >> "$WAVECARD_RECOVERY_SYNCS"
        case "$WAVECARD_RECOVERY_MODE" in
          read-moved-*|read-delayed-true)
            printf '%s\\n' "$5" > "$WAVECARD_RECOVERY_DEVICE/recovered-name"
            if [ "$WAVECARD_RECOVERY_MODE" = read-delayed-true ]; then
              touch "$WAVECARD_RECOVERY_DEVICE/transfer-pending"
            else
              mv "$WAVECARD_RECOVERY_DEVICE/original.png" "$WAVECARD_RECOVERY_DEVICE/$5"
            fi
            printf '%s\\n' '{"type":"atc_stage","stage":"complete-assets"}'
            case "$WAVECARD_RECOVERY_MODE" in
              read-moved-true|read-delayed-true) printf '%s\\n' '{"ok":false,"assetCompletionStarted":true,"error":"interrupted after relocation"}';;
              read-moved-no-terminal) :;;
              read-moved-absent) printf '%s\\n' '{"ok":false,"error":"old helper has no transfer state"}';;
              read-moved-numeric) printf '%s\\n' '{"ok":false,"assetCompletionStarted":0,"error":"malformed transfer state"}';;
              read-moved-string) printf '%s\\n' '{"ok":false,"assetCompletionStarted":"false","error":"malformed transfer state"}';;
              read-moved-null) printf '%s\\n' '{"ok":false,"assetCompletionStarted":null,"error":"malformed transfer state"}';;
              read-moved-numeric-ok) printf '%s\\n' '{"ok":0,"assetCompletionStarted":false,"error":"malformed terminal state"}';;
            esac
            exit 2;;
          sync-failure|sync-cleanup-failure)
            printf '%s\\n' '{"ok":false,"assetCompletionStarted":false,"error":"mock sync failure"}'
            exit 2;;
          sync-once)
            if [ "$(wc -l < "$WAVECARD_RECOVERY_SYNCS")" -eq 1 ]; then
              printf '%s\\n' '{"ok":false,"assetCompletionStarted":false,"error":"transient sync failure"}'
              exit 2
            fi;;
        esac
        printf '%s\\n' '{"ok":true}'
        """)
        let bridge = AirliftBridge.shared
        let target = "/var/mobile/Library/Passes/Cards/abcdefghijklmnopqrstuvwxyza=.pkpass"
        let payload = Data("replacement".utf8)
        let actions: [(String, (@escaping (AirliftReadFailure) -> Void) -> Bool)] = [
            ("single write", { report in
                bridge.writeFile(udid: "mock", target: target, leaf: "cardBackgroundCombined@2x.png", payload: payload, retries: 3, onFailure: report)
            }),
            ("batch write", { report in
                bridge.writeFilesBatch(udid: "mock", target: target, files: [("one.png", payload), ("two.png", payload)], retries: 3, onFailure: report)
            }),
            ("removal", { report in
                bridge.removeFiles(udid: "mock", target: target, leaves: ["FrontFace", "Preview"], retries: 3, onFailure: report)
            })
        ]
        var failed = 0
        var assertions = 0
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        func expect(_ condition: Bool, _ message: String) {
            assertions += 1
            print("\(condition ? "ok" : "not ok") - \(message)")
            if !condition { failed += 1 }
        }
        func lines(_ file: URL) throws -> [String] {
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        func reset(_ mode: String) throws {
            setenv("WAVECARD_RECOVERY_MODE", mode, 1)
            for file in [calls, snapshots, syncs] { try Data().write(to: file) }
        }
        func cleanupSnapshots() throws {
            for path in try lines(snapshots) {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                if fm.fileExists(atPath: parent.path) { try fm.removeItem(at: parent) }
            }
        }
        for (name, action) in actions {
            for mode in ["stage-cleanup-failure", "sync-cleanup-failure", "cleanup-failure"] {
                try reset(mode)
                var errors: [AirliftReadFailure] = []
                let ok = action { errors.append($0) }
                let paths = try lines(snapshots)
                expect(!ok, "\(name): \(mode) fails")
                expect(paths.count == 1, "\(name): \(mode) stops before a second snapshot/retry")
                expect(errors.contains { $0.requiresRecovery }, "\(name): \(mode) propagates recovery requirement")
                expect(paths.allSatisfy { fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("fixture").path) }, "\(name): \(mode) retains original snapshot bytes")
                try cleanupSnapshots()
            }
            try reset("sync-failure")
            var errors: [AirliftReadFailure] = []
            let ok = action { errors.append($0) }
            let paths = try lines(snapshots)
            expect(!ok && paths.count == 3, "\(name): verified cleanup permits bounded retries")
            expect(!errors.isEmpty && !errors.contains { $0.requiresRecovery }, "\(name): terminal sync failure is reported without false recovery warning")
            expect(paths.allSatisfy { !fm.fileExists(atPath: $0) }, "\(name): verified cleanup releases local temporary snapshots")
            try cleanupSnapshots()
            try reset("sync-once")
            errors = []
            let recovered = action { errors.append($0) }
            expect(try recovered && lines(snapshots).count == 2, "\(name): a safe transient failure can recover")
            expect(errors.isEmpty, "\(name): recovered transient errors do not poison the caller's result")
            try cleanupSnapshots()
        }
        // A helper can finish relocating the original and fail before printing
        // its terminal success. Cleanup must preserve that sole original copy.
        let originalFixture = Data("unique original artwork bytes".utf8)
        let originalDeviceURL = device.appendingPathComponent("original.png")
        for mode in ["read-moved-true", "read-moved-no-terminal", "read-moved-absent",
                     "read-moved-numeric", "read-moved-string", "read-moved-null",
                     "read-moved-numeric-ok", "read-delayed-true"] {
            try reset(mode)
            try originalFixture.write(to: originalDeviceURL)
            var readErrors: [AirliftReadFailure] = []
            let read = bridge.readFile(udid: "mock", target: target, leaf: "one.png", retries: 3) { readErrors.append($0) }
            let recordedSnapshots = try lines(snapshots)
            let recoveredName = try String(contentsOf: device.appendingPathComponent("recovered-name"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recoveredDeviceURL = device.appendingPathComponent(recoveredName)
            expect(read == nil && recordedSnapshots.count == 1, "\(mode): ambiguous read stops without a retry")
            expect(readErrors.contains { $0.requiresRecovery }, "\(mode): ambiguous read requires recovery")
            expect(try !lines(calls).contains("finish-write"), "\(mode): no destructive cleanup runs after uncertain relocation")
            expect(recordedSnapshots.allSatisfy {
                fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("fixture").path)
            }, "\(mode): original recovery snapshot survives")
            if mode == "read-delayed-true" {
                expect(fm.fileExists(atPath: originalDeviceURL.path) && !fm.fileExists(atPath: recoveredDeviceURL.path),
                       "delayed transfer is preserved even before a recovered file appears")
                // Simulate the asynchronous device action completing after the
                // failed helper has exited; a missing file at that instant was
                // never sufficient evidence that cleanup would be safe.
                try fm.moveItem(at: originalDeviceURL, to: recoveredDeviceURL)
            }
            expect(try Data(contentsOf: recoveredDeviceURL) == originalFixture,
                   "\(mode): relocated original bytes remain intact")
            let pendingRead = bridge.pendingRecoveryDirectories(udid: "mock")
            expect(pendingRead.count == 1, "\(mode): retained read blocks the same device")
            let fresh = bridge.runCommand(URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: ["--pending", "mock"], timeout: 5)
            let freshPaths = try JSONSerialization.jsonObject(with: Data(fresh.stdout.utf8)) as? [String]
            expect(fresh.exitCode == 0 && freshPaths == pendingRead.map(\.path),
                   "\(mode): recovery gate survives relaunch")
            try fm.removeItem(at: recoveredDeviceURL)
            try cleanupSnapshots()
        }
        expect(!AirliftBridge.failedReadIsProvenPreTransfer(exitCode: -2,
            json: ["ok": false, "assetCompletionStarted": false]),
            "an outer Swift deadline remains ambiguous even with partial terminal diagnostics")

        try reset("sync-failure")
        var safeReadErrors: [AirliftReadFailure] = []
        let safeRead = bridge.readFile(udid: "mock", target: target, leaf: "one.png", retries: 1) { safeReadErrors.append($0) }
        expect(try safeRead == nil && lines(calls).contains("finish-write"),
               "an explicit Boolean pre-transfer failure can clean staging")
        expect(!safeReadErrors.contains { $0.requiresRecovery } && bridge.pendingRecoveryDirectories(udid: "mock").isEmpty,
               "verified pre-transfer cleanup leaves no false recovery gate")

        try reset("restore-cleanup-failure")
        var errors: [AirliftReadFailure] = []
        let data = bridge.readFile(udid: "mock", target: target, leaf: "one.png", retries: 1) { errors.append($0) }
        let paths = try lines(snapshots)
        expect(data == nil && paths.count == 2, "read restoration stops after the first unverified inner cleanup")
        expect(errors.contains { $0.requiresRecovery }, "read restoration propagates nested write recovery requirement")
        expect(paths.allSatisfy { fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("fixture").path) }, "read restoration retains both outer and inner recovery snapshots")
        let outer = paths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        expect(outer.map { fm.fileExists(atPath: $0.appendingPathComponent("recovered.bin").path) } == true, "read restoration retains recovered original bytes")
        try cleanupSnapshots()
        for mode in ["cleanup-failure", "sync-failure", "success"] {
            try reset(mode)
            errors = []
            let ok = bridge.invalidateCache(udid: "mock", cardHash: "abcdefghijklmnopqrstuvwxyza=") { errors.append($0) }
            let paths = try lines(snapshots)
            if mode == "cleanup-failure" {
                expect(!ok && paths.count == 1, "cache invalidation stops before the second extension after unknown cleanup")
                expect(errors.contains { $0.requiresRecovery }, "cache invalidation forwards recovery requirement")
            } else if mode == "sync-failure" {
                expect(!ok && paths.count == 6, "verified cache cleanup allows retries and the second extension")
                expect(!errors.isEmpty && !errors.contains { $0.requiresRecovery }, "noncritical cache failures are forwarded accurately")
            } else {
                expect(ok && paths.count == 2, "cache invalidation success visits both extensions")
                expect(errors.isEmpty, "successful cache invalidation does not report failure")
            }
            try cleanupSnapshots()
        }

        // Restore uses a unique synthetic local original; the fake helpers still
        // handle all writes and no saved card or connected device is touched.
        let originalHash = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let originalURL = CardAssetManager.shared.originalFileURL(for: originalHash)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 5,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = bitmap.bitmapData!
        for x in 0..<8 { for y in 0..<5 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 255
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: originalURL)
        defer { try? fm.removeItem(at: originalURL) }
        for mode in ["cleanup-failure", "restore-cache-failure"] {
            try reset(mode)
            errors = []
            var messages: [String] = []
            let ok = await CardRestoreManager.shared.restoreCard(udid: "mock", cardHash: originalHash,
                onLog: { messages.append($0) }, onFailure: { errors.append($0) })
            let paths = try lines(snapshots)
            expect(!ok, "restore reports \(mode) as incomplete")
            expect(errors.contains { $0.requiresRecovery }, "restore forwards \(mode) recovery requirement to caller")
            expect(paths.count == (mode == "cleanup-failure" ? 1 : 2), "restore stops further operations after \(mode)")
            expect(!messages.contains { $0.contains("Restore complete") }, "restore does not report success after \(mode)")
            expect(paths.contains { fm.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("fixture").path) }, "restore retains recovery snapshot after \(mode)")
            try cleanupSnapshots()
        }
        try fm.removeItem(at: originalURL)

        try reset("hold-snapshot")
        let activeOperation = Task.detached {
            bridge.writeFile(udid: "mock", target: target, leaf: "one.png", payload: payload, retries: 1)
        }
        for _ in 0..<200 {
            if fm.fileExists(atPath: ready.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        expect(fm.fileExists(atPath: ready.path), "held mock operation reaches a live recovery workspace")
        expect(bridge.pendingRecoveryDirectories(udid: "mock").isEmpty, "the current process excludes its active workspace from pending recovery")
        let activeSucceeded = await activeOperation.value
        expect(activeSucceeded && bridge.pendingRecoveryDirectories(udid: "mock").isEmpty, "completed verified operation releases workspace ownership and removes its record")
        try cleanupSnapshots()

        try reset("cleanup-failure")
        errors = []
        _ = actions[0].1 { errors.append($0) }
        let pending = bridge.pendingRecoveryDirectories(udid: "mock")
        expect(pending.count == 1 && canonical(pending[0].deletingLastPathComponent()) == canonical(recoveryRoot), "retained workspace lives under the persistent recovery root")
        expect(bridge.pendingRecoveryDirectories(udid: "other-device").isEmpty, "a valid recovery tag isolates devices")
        let tag = try String(contentsOf: pending[0].appendingPathComponent("device.udid"), encoding: .utf8)
        expect(tag == "mock", "workspace records the device before any snapshot or staging")
        let restarted = bridge.runCommand(URL(fileURLWithPath: CommandLine.arguments[0]), arguments: ["--pending", "mock"], timeout: 5)
        let restartedPaths = try JSONSerialization.jsonObject(with: Data(restarted.stdout.utf8)) as? [String]
        expect(restarted.exitCode == 0 && restartedPaths == pending.map(\.path), "a fresh process discovers retained recovery records after relaunch")
        expect(fm.fileExists(atPath: pending[0].path), "recovery discovery does not remove an existing record")
        try cleanupSnapshots()

        let unknown = recoveryRoot.appendingPathComponent("unknown-workspace", isDirectory: true)
        let foreign = recoveryRoot.appendingPathComponent("foreign-workspace", isDirectory: true)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
        try fm.createDirectory(at: foreign, withIntermediateDirectories: false)
        try Data("other-device".utf8).write(to: foreign.appendingPathComponent("device.udid"))
        expect(bridge.pendingRecoveryDirectories(udid: "mock").map(canonical) == [canonical(unknown)], "a missing tag conservatively blocks the connected device")
        expect(Set(bridge.pendingRecoveryDirectories(udid: "other-device").map(canonical)) == Set([canonical(unknown), canonical(foreign)]), "unknown and matching-device records are both reported")
        try reset("success")
        let success = actions[0].1 { _ in }
        expect(success && fm.fileExists(atPath: unknown.path) && fm.fileExists(atPath: foreign.path), "successful operation cleans only its own workspace")
        try fm.removeItem(at: unknown)
        try fm.removeItem(at: foreign)

        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blockedRoot)
        setenv("WAVECARD_RECOVERY_ROOT", blockedRoot.path, 1)
        for (name, action) in actions {
            try reset("success")
            errors = []
            let ok = action { errors.append($0) }
            expect(try !ok && lines(calls).isEmpty, "\(name) aborts before contacting helpers if recovery workspace cannot be created")
            expect(errors.contains { $0.message.contains("persistent recovery workspace") }, "\(name) reports local recovery workspace failure")
        }
        try reset("success")
        errors = []
        let blockedRead = bridge.readFile(udid: "mock", target: target, leaf: "one.png", retries: 1) { errors.append($0) }
        expect(try blockedRead == nil && lines(calls).isEmpty, "read aborts before contacting helpers if recovery workspace cannot be created")
        expect(errors.contains { $0.message.contains("persistent recovery workspace") }, "read reports local recovery workspace failure")
        expect(bridge.pendingRecoveryDirectories(udid: "mock").map(canonical) == [canonical(blockedRoot)], "an invalid recovery root blocks conservatively")
        setenv("WAVECARD_RECOVERY_ROOT", recoveryRoot.path, 1)
        print("\(assertions) assertions, \(failed) failures")
        if failed > 0 { exit(1) }
    }
}
