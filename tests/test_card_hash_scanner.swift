import Foundation

@main
struct CardHashScannerTest {
    static func main() {
        let realHashes = [
            "Coza99TKbpVUZHdDTiu7KMFfhds=",
            "WQkIbdc-58Ppo3uBBCLI7xNr3xw=",
            "7UHh1luWDAS7sqYVOxZIp4l9Wtc=",
            "IYjbRmaXIn2BMlc5AahmFL0kYPM=",
            "pWQfx7iekgHAPpmyf3QCbJQ84vA=",
            "B5r9kmes0PpVASDX3EKOPGk7nH4=",
            "amJRRxNq8hLQmZagHRhVdblZ7W8=",
            "2eh9hl5BmTIWe2dXzzFcwObvyN8=",
            "XVOqkBgkvMMn5I9hDGNofAFSOMY=",
        ]

        var failed = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                failed += 1
                fputs("FAIL: \(message)\n", stderr)
            }
        }

        for hash in realHashes {
            expect(CardHashScanner.isValid(hash), "valid \(hash)")
            let lines = [
                "file:///var/mobile/Library/Passes/Cards/\(hash).pkpass/en.lproj/actions.strings",
                "/Library/Passes/Cards/\(hash).pkpass",
                "Library/Passes/Cards/\(hash)",
                "/var/mobile/Library/Passes/Cards/\(hash).pkpass",
                "passUniqueID:\(hash)",
            ]
            for line in lines {
                let found = CardHashScanner.hashes(in: line)
                expect(found == [hash], "line \(line) -> \(found)")
            }
            expect(CardHashScanner.hashes(in: "/Library/Passes/Cards/\(hash)") == [hash], "bare path \(hash)")
        }

        expect(
            CardHashScanner.hashes(in: "/Library/Passes/Cards/Coza99TKbpVUZHdDTiu7KMFfhds=") == ["Coza99TKbpVUZHdDTiu7KMFfhds="],
            "path is not itself a hash"
        )
        expect(!CardHashScanner.isValid("/Library/Passes/Cards/Coza99TKbpVUZHdDTiu7KMFfhds="), "reject path")
        expect(!CardHashScanner.isValid("Library/Passes/Cards/Coza99TKbpVUZHdDTiu7KMFfhds="), "reject relative path")
        expect(
            CardHashScanner.hashes(in: "file:///var/mobile/Library/Passes/Cards/AAAAAAAAAAAAAAAAAAAAAAAAAAA=.pkpass/en.lproj/actions.strings")
                == ["AAAAAAAAAAAAAAAAAAAAAAAAAAA="],
            "ios18 fixture"
        )

        expect(
            CardHashScanner.quotedPassID(in: "    \"VwQQFLDxEpWKfBeCbF6ICdGzEI8=\"") == "VwQQFLDxEpWKfBeCbF6ICdGzEI8=",
            "quoted payment pass id"
        )
        expect(CardHashScanner.quotedPassID(in: "\"has spaces here\"") == nil, "reject quoted sentence")
        expect(CardHashScanner.quotedPassID(in: "VwQQFLDxEpWKfBeCbF6ICdGzEI8=") == nil, "require quotes")

        if failed == 0 {
            print("ok")
        } else {
            fputs("\(failed) failed\n", stderr)
            exit(1)
        }
    }
}
