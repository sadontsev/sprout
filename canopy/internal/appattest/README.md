# Capturing a real attestation fixture

`TestRealDeviceAttestation` verifies this package against a genuine App Attest object from a real
device. It **skips** when no fixture is present, which is the state of a fresh clone.

The fixture is not committed. Apple's leaf certificate carries `<TEAMID>.<bundle id>` in plaintext,
so publishing one publishes the developer account behind the app.

## Why bother capturing one

Every other test here builds its attestation with the same code that parses it. Those prove each
rejection path, but a fixture produced and read by one codebase agrees with itself even when both
halves are wrong about the real wire format — and that is not hypothetical. This package once
verified assertions against the nonce directly while its own fixture signed the nonce directly. The
pair agreed perfectly. Apple signs `SHA-256(nonce)`, and only a real device ever said so.

If you change the attestation or assertion parsing, capture a fixture and run this test.

## Files

Four, all gitignored, all in `testdata/`:

| File | Contents |
|---|---|
| `attestation.bin` | the raw CBOR attestation object from `DCAppAttestService.attestKey` |
| `attestation.keyid` | the key id string that `generateKey` returned |
| `attestation.clientdata` | the exact client-data bytes the attestation was made over |
| `attestation.appid` | `<TEAMID>.<bundle id>` — cannot be derived from the attestation, only its SHA-256 appears there |

`apple-app-attest-root.pem` **is** committed: it is Apple's public root certificate and identifies
nobody.

## Capturing

`Sprout/Realtime/AttestCapture.swift` in the iOS app writes all four to the app container on a debug
build. Pull them off the device and drop them in `testdata/`.

Then pin the clock: App Attest leaf certificates are short-lived — three days for the one this was
written against — so the test verifies against the moment of capture, not `time.Now()`. Update the
`captured` timestamp in `real_attest_test.go` to when yours was made, or the test rots into a chain
failure that reads like a parser bug.
