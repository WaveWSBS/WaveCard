#import <Foundation/Foundation.h>
#import "../Sources/wallet_trace_filter.h"

int main(void) {
    @autoreleasepool {
        unsetenv("WAVECARD_SYSLOG_UNFILTERED");
        NSArray<NSString *> *accepted = @[
            @"OtherApp(CoreFoundation): /Library/Passes/Cards/AAAAAAAAAAAAAAAAAAAAAAAAAAA=.pkpass",
            @"passd(PassKit): PDCardFileManager: writing card AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"passd(PassKit): PDCardFileManager:  writing card AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"passd(PassKit): PDPassLibrary: wrote pass AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"Passbook(PassKitUI): VerificationCheck.AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"Passbook(PassKitUI): selected pass uniqueID: <private>",
            @"Passbook(PassKitUI): Dashboard loading (details): for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
            @"nfcd(NearField): passIDs[InSession]: {(\n\"AAAAAAAAAAAAAAAAAAAAAAAAAAA=\"\n)}",
            @"nfcd(NearField): setActivePaymentApplet: requestedApplet: {identifier=A00000000310100100000020}",
            @"OtherApp(PassKitCore): Dashboard loading: for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
            @"passd(PassKit): NanoPasses",
            @"passd(PassKit): resource.pkcache",
        ];
        NSArray<NSString *> *rejected = @[
            @"OtherApp(CoreFoundation): Dashboard loading: for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
            @"OtherApp(CoreFoundation): selected pass uniqueID: AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"OtherApp(CoreFoundation): PDCardFileManager: writing card AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"OtherApp(CoreFoundation): setActivePaymentApplet: requestedApplet: {identifier=A00000000310100100000020}",
            @"nfcd(NearField): background NFC state changed",
            @"nfcd(NearField): identifier=A00000000310100100000020",
            @"nfcd(NearField): \"A00000000310100100000020\"",
            @"nfcd(NearField): requestedApplet: {identifier=A00000000310100100000020}",
            @"nfcd(NearField): setActivePaymentApplet: state changed",
            @"OtherApp(CoreFoundation): Wallet Dashboard loading: for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
            @"OtherApp(CoreFoundation): AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            @"nfcd impostor(CoreFoundation): Dashboard loading: for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
            @"OtherApp(CoreFoundation)\npassd(PassKit): Dashboard loading: for AAAAAAAAAAAAAAAAAAAAAAAAAAA=, unknown",
        ];
        unsigned failures = 0;
        for (NSString *record in accepted) {
            if (!WaveCardTraceLineHasPassSignal(record)) { fprintf(stderr, "FAIL accept: %s\n", record.UTF8String); failures++; }
        }
        for (NSString *record in rejected) {
            if (WaveCardTraceLineHasPassSignal(record)) { fprintf(stderr, "FAIL reject: %s\n", record.UTF8String); failures++; }
        }
        setenv("WAVECARD_SYSLOG_UNFILTERED", "1", 1);
        if (!WaveCardTraceLineHasPassSignal(@"unrelated diagnostic")) failures++;
        unsetenv("WAVECARD_SYSLOG_UNFILTERED");
        if (failures) return 1;
        printf("ok (%lu accepted, %lu rejected, unfiltered override)\n", (unsigned long)accepted.count, (unsigned long)rejected.count);
    }
    return 0;
}
