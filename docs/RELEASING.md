# Releasing Hoply

For maintainers. `.github/workflows/release.yml` builds, tests and packages a universal (Apple silicon + Intel)
`Hoply-<version>.dmg` on the `xcode-27` runner with Xcode 27.2. Pushing a tag `v<version>` signs it with a Developer
ID, notarizes it, publishes it as a GitHub Release on `Milos5611/homebrew-hoply` and updates the Homebrew cask
there. Running the workflow by hand (Actions → Release → Run workflow) only uploads the DMG as a build artifact.
Without the secrets below the DMG is ad-hoc signed, which proves the build but is blocked by Gatekeeper on other Macs.

## Where releases live

Releases are published on `Milos5611/homebrew-hoply`, not on this repo. That repo is also the Homebrew tap
(`brew install --cask milos5611/hoply/hoply`), and every installed copy checks `https://hoply.dev/appcast.xml`,
which the site redirects to `https://github.com/Milos5611/homebrew-hoply/releases/latest/download/appcast.xml`.
`https://hoply.dev/download` redirects to that release's `Hoply.dmg`. The feed URL is baked into every build, so the
releases can move to another host later by changing only the redirects in the site's `public/_redirects`. The
appcast's download and release-notes links point at GitHub directly.

`HOPLY_REPO` (a workflow-level env var in `release.yml`, also read by `scripts/package.sh` and `scripts/cask.sh`,
default `Milos5611/homebrew-hoply`) names the hosting repo.

## One-time setup

1. Join the Apple Developer Program (https://developer.apple.com/programs/enroll/, 99 USD a year; an individual
   account is enough).
2. Create a **Developer ID Application** certificate: Xcode → Settings → Accounts → your team → Manage Certificates →
   \+ → Developer ID Application. Then Keychain Access → My Certificates → that certificate → Export as `.p12` with a
   password.

   macOS 27 no longer ships Keychain Access. There, make the key and the `.p12` with OpenSSL (Homebrew's `openssl`)
   instead:

   ```bash
   openssl req -new -newkey rsa:2048 -nodes -keyout DeveloperID.key -out DeveloperID.csr \
     -subj "/CN=<your name>/emailAddress=<your email>"
   ```

   Upload `DeveloperID.csr` at https://developer.apple.com/account/resources/certificates → + → Developer ID
   Application (G2 Sub-CA), download the certificate, then bundle it with Apple's Developer ID G2 intermediate:

   ```bash
   openssl x509 -inform der -in developerID_application.cer -out DeveloperID.pem
   curl -fsSLO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
   openssl x509 -inform der -in DeveloperIDG2CA.cer -out DeveloperIDG2CA.pem
   openssl pkcs12 -export -inkey DeveloperID.key -in DeveloperID.pem -certfile DeveloperIDG2CA.pem \
     -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out DeveloperID.p12
   ```

   The 3DES/SHA1 flags keep the `.p12` in the older format that macOS's `security import` (which the workflow runs)
   reads; OpenSSL's newer AES default may be refused. Keep the `.p12` and its password somewhere safe and delete the
   other files once the secrets are set. The current certificate expires on 2027-12-11; renew it before then or
   releases can no longer be signed.
3. Create an App Store Connect API key for notarization: https://appstoreconnect.apple.com/access/integrations/api →
   Team Keys → + (access: Developer). Download the `.p8` (only possible once) and note its Key ID and the Issuer ID
   above the list.
4. Add the repository secrets (GitHub → Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password |
   | `KEYCHAIN_PASSWORD` | any random string, e.g. `openssl rand -base64 24` |
   | `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<KEYID>.p8 \| pbcopy` |
   | `NOTARY_KEY_ID` | the key's Key ID |
   | `NOTARY_ISSUER_ID` | the Issuer ID |
   | `SPARKLE_PUBLIC_KEY` | the public key from step 5 |
   | `SPARKLE_PRIVATE_KEY` | the contents of the exported private key file from step 5 |
   | `TAP_TOKEN` | the fine-grained token from step 6 |

5. Create the update signing key (Sparkle, EdDSA) once, after a `swift build` has fetched Sparkle:
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account hoply`. It stores the private key in your login
   Keychain and prints the public key. Export the private key with `generate_keys --account hoply -x hoply-sparkle.key`,
   paste its contents into the secret, then delete the file. Keep the Keychain item: losing the key means installed
   copies can no longer verify updates.
6. Create the public repo that hosts every release and is also the Homebrew tap: GitHub → New repository →
   `homebrew-hoply`, Public, with "Add a README file" ticked, so `main` has a commit (releases are tagged on it, and the
   workflow pushes `Casks/hoply.rb` to it). Then create its token: GitHub → Settings → Developer settings → Personal
   access tokens → Fine-grained tokens → Generate new token; Repository access → Only select repositories →
   `Milos5611/homebrew-hoply`; Permissions → Repository → Contents: Read and write (Metadata: Read-only comes with
   it). Save it as the `TAP_TOKEN` secret here, and renew it before its expiry date or releases stop publishing.

## Release

```bash
git tag -a v0.1.0 -m "What changed"
git push origin v0.1.0
```

The tag sets the version (`CFBundleShortVersionString`); the build number (`CFBundleVersion`, which Sparkle compares)
is the commit count, so release from `main`. The tag message becomes the release notes in the update window and on the
release page; without one, both link to https://hoply.dev/changelog.

The workflow publishes `Hoply-<version>.dmg`, a copy named `Hoply.dmg` and `appcast.xml` on
`Milos5611/homebrew-hoply`, then commits `Casks/hoply.rb` there as github-actions[bot] (`scripts/cask.sh <version> <sha256>`
prints it). It publishes nothing unless all secrets are set, because a build without the Sparkle keys never
checks for updates again; the run then ends with a "No release published" warning. If the release is published but
the cask push fails, fix `Casks/hoply.rb` on the tap by hand.

**Notarization timeout.** `package.sh` waits for `notarytool` with `--timeout 30m`. A team's first notarization can
take longer (Hoply's first took 41 minutes), and the job then fails although Apple is still working on it. Find the
submission id in the job log, check it with your API key:

```bash
xcrun notarytool info <submission id> --key AuthKey_<KEYID>.p8 --key-id <key id> --issuer <issuer id>
```

and once it says `Accepted`, re-run the failed job. Later submissions take a few minutes.

To build the same DMG locally:

```bash
HOPLY_SIGN_IDENTITY="Developer ID Application: <name> (<team id>)" \
NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… SPARKLE_PUBLIC_KEY=… scripts/package.sh
```

It signs the update with the Keychain key unless `SPARKLE_PRIVATE_KEY` is set; `HOPLY_REPO`, `HOPLY_FEED_URL` and
`HOPLY_DOWNLOAD_URL` override the URLs above. Without `SPARKLE_PUBLIC_KEY` it writes no appcast and the app never
checks for updates.

## After a release

A tester installs with `brew install --cask milos5611/hoply/hoply` (Homebrew adds the tap itself), or downloads the
DMG from https://hoply.dev/download, then connects their agents in Settings → Agents. The cask declares
`auto_updates`, so `brew upgrade` leaves Hoply to Sparkle unless `--greedy` is passed; `brew uninstall --zap --cask
hoply` also deletes Hoply's data, usage history included, but not the agent hooks, so disconnect agents in Settings →
Agents first. Release builds check for updates once a day (Settings → Updates turns that off) and show a new version
at the bottom of the panel; "Check for Updates…" is also in the status item's right-click menu. Builds from
`scripts/install.sh` or `swift run` never update themselves.

The site (hoply.dev) gets a changelog entry and its `softwareVersion` / `datePublished` bumped for each release.
