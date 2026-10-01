# Wallet card detection validation

## Reproduction and cause

An iPhone 15 Pro on iOS 18.6.2 connected successfully, but scanning found no cards
after double-clicking the side button, authenticating with Face ID, and selecting
cards. Comparing both log services during the same interaction showed that
`com.apple.syslog_relay` omitted the card paths, while `com.apple.os_trace_relay`
included them in multiline resource lookup messages.

The native helper now requests the unified activity stream and decodes its
framed records through the MobileDevice service connection. This keeps the app
self-contained. Existing card filters still identify the `.pkpass` paths.
The app also displays helper diagnostics and resets its scanning state if the
reader exits unexpectedly.

## Verified environment

| Component | Version |
| --- | --- |
| iPhone | iPhone 15 Pro (`iPhone16,1`), iOS 18.6.2 |
| Mac | MacBook Air (M3, 2024), macOS 26.6.2 |
| Source baseline | WaveCard 1.2.3, commit `02b5ba8` |

The original report included a macOS 26.2 screenshot; the Mac used for this
validation reported macOS 26.6.2. Do not treat macOS 26.2 as verified.

After the change, the app detected eight card identifiers during live scanning,
and the tester confirmed that cards appeared. No card artwork was flashed as
part of detection testing. Stopping the helper reset the scanning UI, and a
subsequent scan connected successfully without losing the detected cards.

The iPhone 17 / iOS 27 case in [issue #28](https://github.com/WaveWSBS/WaveCard/issues/28)
has not been tested. Other device and OS combinations still need verification.

## Automated checks

```sh
# Native log-frame reader test
xcrun clang -fobjc-arc -framework Foundation tests/test_os_trace.m -o /tmp/test_os_trace && /tmp/test_os_trace

# Swift card-hash scanner test
swiftc -O -parse-as-library tests/test_card_hash_scanner.swift Sources/Swift/CardHashScanner.swift -o /tmp/test_card_hash_scanner && /tmp/test_card_hash_scanner

bash build.sh
```

Scanner tests cover fragmented and coalesced frames, the different byte orders
of plist replies and activity records, disconnects, malformed lengths, truncated
records, and multiline card paths reaching the existing detection patterns.
Fixtures contain synthetic identifiers only. The native reader tests require
macOS and Xcode command-line tools.

## Help verify other devices

If your device connects but no cards appear, try this branch's build and report
your iPhone model, iOS version, macOS version, the exact WaveCard commit tested,
and whether cards appeared after selecting them in Wallet. Include any scanner
error message, but do not include raw device logs or full card identifiers.
