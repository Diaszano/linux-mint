# mise signature test fixture

The Bats fixture creates a temporary `mise-v2026.10.18-linux-x64` shell stub, its SHA-256 manifest (using the signed upstream `./asset-name` spelling), and a marker file called `SHASUMS256.txt.minisig`. The test-only `minisign` command accepts that marker only when the production command supplies the pinned public key. This checks command ordering and fail-closed behavior; it is not a cryptographic signature and must never be used as a release trust anchor.

The network-enabled disposable VM test uses the official release manifest and signature with the distribution `minisign` binary. The only trusted key is the pinned public key in `config/mise-release.conf`. No signature bytes are copied into this fixture because release signatures must be obtained from the official URL and verified against that key.
