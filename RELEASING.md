# macOS release packaging

Parrot Lab currently ships as an **ad-hoc-signed, non-notarized development
build**. The project does not currently use a paid Apple Developer Program
membership or a Developer ID Application certificate.

This is a temporary distribution workflow. It provides a structurally valid,
signed `.app` and a verified ZIP for GitHub Releases, but it cannot provide the
Gatekeeper experience of a Developer-ID-signed and Apple-notarized release.

## Build and package the standard release

On Apple Silicon macOS with Xcode command-line tools installed, run:

```sh
cd parrot-lab
./scripts/build-app.sh
```

This performs the Swift Release build, assembles the normal application
bundle, passes it through the release packager, installs the exact packaged app
locally, and produces:

```text
~/Applications/Parrot Lab.app
dist/Parrot-Lab-macOS-arm64.zip
```

Upload `Parrot-Lab-macOS-arm64.zip` as the GitHub Release asset.

## Package an existing app bundle

The release helper can package a previously assembled app:

```sh
./scripts/package-macos-release.sh \
  "/path/to/Parrot Lab.app" \
  "/path/to/Parrot-Lab-macOS-arm64.zip"
```

The output path is optional and defaults to `dist/Parrot-Lab-macOS-arm64.zip`.
The script copies the input app to a clean temporary directory, leaving the
input unchanged, and then:

1. removes extended attributes from the temporary copy;
2. ad-hoc signs it with:

   ```sh
   codesign --force --deep --sign - "/path/to/Parrot Lab.app"
   ```

3. verifies it with:

   ```sh
   codesign --verify --deep --strict --verbose=2 "/path/to/Parrot Lab.app"
   ```

4. confirms that `codesign` reports `Signature=adhoc`;
5. runs the offline application self-test;
6. creates and integrity-tests the ZIP;
7. extracts the ZIP and verifies the signature of the archived app again;
8. prints the release ZIP's SHA-256 digest.

The script uses `set -eu` and does not publish an output archive unless every
step succeeds.

## Tester first-launch instructions

Parrot Lab is currently distributed as an ad-hoc-signed, non-notarized
development build because the project does not yet use a paid Apple Developer
ID certificate.

On first launch, macOS may block the application. Try:

1. Extract the downloaded ZIP.
2. Move **Parrot Lab.app** to `/Applications`.
3. Right-click **Parrot Lab.app**.
4. Choose **Open**.
5. Confirm **Open**.

If macOS still refuses to launch it, advanced users can remove the quarantine
attribute from this app only:

```sh
xattr -dr com.apple.quarantine "/Applications/Parrot Lab.app"
```

Then right-click the app and choose **Open** again. Do not disable Gatekeeper
globally.

## Future Developer ID migration

If the project later joins the Apple Developer Program, this packaging stage
can be migrated deliberately to Developer ID Application signing and Apple
notarization. Until then, the release scripts must not expect Apple account
credentials, private keys, `.p12` files, provisioning profiles, or notarization
secrets.
