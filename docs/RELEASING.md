# Releasing Hoply

For maintainers. `.github/workflows/release.yml` builds, tests and packages a universal (Apple silicon + Intel)
`Hoply-<version>.dmg` on the `xcode-27` runner with Xcode 27.2. Pushing a tag `v<version>` signs it with a Developer
ID, notarizes it, publishes it as a GitHub Release on this repo (`Milos5611/hoply`) and updates the Homebrew cask on
the tap `Milos5611/homebrew-hoply`. Running the workflow by hand (Actions → Release → Run workflow) only uploads the
DMG as a build artifact. Without the secrets below the DMG is ad-hoc signed, which proves the build but is blocked by
Gatekeeper on other Macs.

## Where releases live

From 0.1.6 on, releases are published on this repo, `Milos5611/hoply`, so its stars count for Homebrew's notability
rules. 0.1.0–0.1.5 stay on `Milos5611/homebrew-hoply`, which remains the Homebrew tap
(`brew install --cask milos5611/hoply/hoply`); the workflow only pushes `Casks/hoply.rb` there, and `TAP_TOKEN` is
needed for that push alone. The release itself is created with the workflow's own `GITHUB_TOKEN` (the job has
`contents: write`).

Every installed copy checks `https://hoply.dev/appcast.xml`, which the site redirects to
`https://github.com/<host>/releases/latest/download/appcast.xml`; `https://hoply.dev/download` redirects to that
release's `Hoply.dmg`. The feed URL is baked into every build, so the releases move to another host by changing only
those two lines in the site's `public/_redirects`. The appcast's download and release-notes links and the cask's
`url` point at GitHub directly.

**Switching the redirects.** Through 0.1.5 both lines in `public/_redirects` (`/download`, `/appcast.xml`) point at
`Milos5611/homebrew-hoply`. Switch them to `Milos5611/hoply` right after the first release lands there (the workflow
run is green and the release lists `appcast.xml`), not before: until then that repo has no release, and installed
copies would see a broken feed. Until the switch, installed copies keep reading 0.1.5's feed and see no update.

`HOPLY_REPO` (a workflow-level env var in `release.yml`, also read by `scripts/package.sh` and `scripts/cask.sh`,
default `Milos5611/hoply`) names the release host; `HOPLY_TAP` (workflow-level, `Milos5611/homebrew-hoply`) names the
tap.

## Signed update feed

The appcast is signed as a whole, not just the DMG. `package.sh` signs `build/appcast.xml` in place with Sparkle's
`sign_update` and the same EdDSA key as the DMG, as the last change to the file, then checks it with
`sign_update --verify`. After publishing, the workflow downloads the release's `appcast.xml` and runs
`sign_update --verify` on it again; if that fails, the job fails before the cask is updated. Release builds from 0.1.6
on set `SURequireSignedFeed`, so they reject a feed without a valid signature; older copies ignore the signature.

- Feed signing can never be turned off: once a build with `SURequireSignedFeed` has shipped, every appcast must be
  signed with the same key, or those copies stop updating.
- Never edit a published `appcast.xml` by hand. `sign_update` adds a warning comment before `<rss>` and the signature
  in a `sparkle-signatures` comment at the end, and any later change breaks it. To fix one, re-sign the corrected file
  with `sign_update`, check it with `--verify`, then replace the asset
  (`gh release upload v<version> appcast.xml --clobber --repo Milos5611/hoply`), or delete the release.
- The signature has no timestamp, so an old release never needs re-signing. Sparkle's
  `SUSignedFeedFailureExpirationInterval` (20 days by default; Hoply keeps the default) is not a signature lifetime
  but a fail-open fallback: after 20 days of failed feed checks Sparkle drops to a safe mode (no release notes, no
  critical or automatic install; the DMG still needs its EdDSA signature or Developer ID). It is the way back if the
  key is ever lost.
- A bad feed signature stops every copy from 0.1.6 on from updating, which is why the workflow checks the published
  file.

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
   paste its contents into the secret, then delete the file. Keep the Keychain item: the key signs both the DMG and
   the appcast, and losing it means installed copies can no longer verify updates.
6. Create the public Homebrew tap repo: GitHub → New repository → `homebrew-hoply`, Public, with "Add a README file"
   ticked, so `main` has a commit (the workflow pushes `Casks/hoply.rb` to it). Then create its token: GitHub →
   Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token; Repository
   access → Only select repositories → `Milos5611/homebrew-hoply`; Permissions → Repository → Contents: Read and write
   (Metadata: Read-only comes with it). Save it as the `TAP_TOKEN` secret here, and renew it before its expiry date or
   the cask push fails after the release is published.

## Release

```bash
git tag -a v0.1.0 -m "What changed"
git push origin v0.1.0
```

The tag sets the version (`CFBundleShortVersionString`); the build number (`CFBundleVersion`, which Sparkle compares)
is the commit count, so release from `main`. The tag message becomes the release notes in the update window and on the
release page; without one, both link to https://hoply.dev/changelog.

The workflow publishes `Hoply-<version>.dmg`, a copy named `Hoply.dmg` and `appcast.xml` on this repo, verifies the
published appcast's signature (see Signed update feed), then commits `Casks/hoply.rb` to the tap as
github-actions[bot] (`scripts/cask.sh <version> <sha256>` prints it). It publishes nothing unless all secrets are set
(`TAP_TOKEN` included), because a build without the Sparkle keys never checks for updates again; the run then ends
with a "No release published" warning. If the release is published but the cask push fails, fix `Casks/hoply.rb` on
the tap by hand.

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

It signs the DMG and the appcast with the Keychain key unless `SPARKLE_PRIVATE_KEY` is set; `HOPLY_REPO`,
`HOPLY_FEED_URL` and `HOPLY_DOWNLOAD_URL` override the URLs above. Without `SPARKLE_PUBLIC_KEY` it writes no appcast
and the app never checks for updates.

## After a release

A tester installs with `brew install --cask milos5611/hoply/hoply` (Homebrew adds the tap itself), or downloads the
DMG from https://hoply.dev/download, then connects their agents in Settings → Agents. The cask declares
`auto_updates`, so `brew upgrade` leaves Hoply to Sparkle unless `--greedy` is passed; `brew uninstall --zap --cask
hoply` also deletes Hoply's data, usage history included, but not the agent hooks, so disconnect agents in Settings →
Agents first. Release builds check for updates at launch and every hour (Settings → Updates turns that off), show a
new version as a dot on the menu bar icon, a card at the top of the panel and one notification, and install it when the
user chooses it (or on quit, with "Download and install updates automatically" on); "Check for Updates…" is also in the
status item's right-click menu. Builds from `scripts/install.sh` or `swift run` never update themselves.

The site (hoply.dev) gets a changelog entry and its `softwareVersion` / `datePublished` bumped for each release.
