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

        expect(
            CardHashScanner.passIDs(in: "    \"AbCdEfGhIjKlMnOpQrStUvWxYz0123\"") == ["AbCdEfGhIjKlMnOpQrStUvWxYz0123"],
            "quoted id of non-28 length is detected"
        )
        expect(
            CardHashScanner.passIDs(in: "    \"VwQQFLDxEpWKfBeCbF6ICdGzEI8=\"") == ["VwQQFLDxEpWKfBeCbF6ICdGzEI8="],
            "quoted id is not duplicated"
        )

        let a = String(repeating: "A", count: 27) + "="
        let b = String(repeating: "B", count: 27) + "="
        let dashboard32 = String(repeating: "C", count: 32)
        let aid = "A00000000310100100000020"
        let long = String(repeating: "D", count: 45)
        let records: [(String, [String])] = [
            ("Passbook(PassKitUI): Dashboard loading (details): for \(a), pass feature unknown", [a]),
            ("Passbook(PassKitUI): Dashboard loading (details): \(dashboard32) - m:NO, sm:NO", [dashboard32]),
            ("passd(PassKit): PDCardFileManager: writing card \(a)", [a]),
            ("passd(PassKit): PDPassLibrary: wrote pass \(a)", [a]),
            ("passd(PassKit): VerificationCheck.\(a)", [a]),
            ("Passbook(PassKitUI): updated selected pass uniqueID: \"\(a)\"", [a]),
            ("nfcd(NearField): passIDs[InSession]: {(\n  \"\(a)\",\n  \"\(dashboard32)\"\n)} passIDs[global]: {(\"\(b)\")}", [a, dashboard32, b]),
            ("nfcd(NearField): passIDs[global]: {(\"\(a)\", \"\(a)\")}", [a]),
            ("OtherApp(CoreFoundation): /var/mobile/Library/Passes/Cards/\(a).pkpass/en.lproj/a", [a]),
            ("OtherApp(CoreFoundation): Dashboard loading: for \(a), unknown", []),
            ("OtherApp(CoreFoundation): passIDs[InSession]: {(\"\(a)\")}", []),
            ("nfcd(NearField): setActivePaymentApplet: requestedApplet: {identifier=\(aid)}", []),
            ("nfcd(NearField): setActivePaymentApplet: requestedApplet: {\"identifier\":\"\(aid)\"}", []),
            ("nfcd(NearField): \"\(aid)\"", []),
            ("nfcd(NearField): \"\(a)\"", []),
            ("nfcd(NearField): identifier=\(a)", []),
            ("Passbook(PassKitUI): selected pass uniqueID: <private>, diagnostic \(a)", []),
            ("passd(PassKit): PDCardFileManager: writing card <redacted>, diagnostic \(a)", []),
            ("Passbook(PassKitUI): Dashboard loading: for \(long), diagnostic \(a)", []),
            ("Passbook(PassKitUI): selected pass uniqueID: \(long), diagnostic \(a)", []),
            ("passd(PassKit): /Library/Passes/Cards/\(long).pkpass diagnostic \(a)", []),
            ("passd(PassKit): /Library/Passes/Cards/\(a).pkpassSuffix", []),
            ("nfcd(NearField): passIDs[InSession]: {(\"\(long)\")} diagnostic \(a)", []),
            ("nfcd(NearField): passIDs[InSession]: {(\"\(a)\", malformed)}", []),
            ("nfcd(NearField): passIDs[InSession]: {(\"\(a)\" diagnostic", []),
            ("nfcd(NearField): passIDs[unknown]: {(\"\(a)\")}", []),
            ("nfcd(NearField): passIDs[InSession]: {(<private>)} \"\(aid)\"", []),
            ("Passbook(PassKitUI): passUniqueID:\(a)", [a]),
            ("passd(PassKit): card diagnostic \(a)", [a]),
            ("passd(PassKit): unrelated \(a)", []),
            ("passd(PassKit): card diagnostic \(a)=", []),
            ("OtherApp(CoreFoundation): /Library/Passes/Cards/\(b).pkpass Dashboard loading: for \(a), x", [b]),
        ]
        for (record, expected) in records {
            let found = CardHashScanner.detectedPassIDs(inRecord: record)
            expect(found == expected, "record \(record) -> \(found), expected \(expected)")
        }

        if failed == 0 {
            print("ok")
        } else {
            fputs("\(failed) failed\n", stderr)
            exit(1)
        }
    }
}
