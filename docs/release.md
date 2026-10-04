# Release artifacts

One release version produces two static Linux executables, each containing the production console assets, and one checksum manifest. Native release builds require Node.js 24/npm in addition to the pinned Go toolchain; the build installs `web/package-lock.json` and rebuilds assets before compiling. The Docker build performs this in a separate Node build stage, so the runtime image has no Node process or frontend package manager:

```sh
scripts/release.sh build v1.0.0 dist/v1.0.0
scripts/release.sh verify dist/v1.0.0
```

The filenames are `dans_VERSION_linux_amd64`, `dans_VERSION_linux_arm64`, and `SHA256SUMS`. Builds disable CGO and VCS metadata, trim source paths, clear the Go build ID, and inject the displayed version. `scripts/release_test.sh` builds twice, compares the artifacts byte-for-byte, verifies both embedded target architectures, and proves that verification rejects a modified or larger-than-24-MiB executable.

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow repeats the reproducibility and tamper tests, builds and verifies both executable architectures, publishes all three files to the matching GitHub release, and pushes the production image for `linux/amd64` and `linux/arm64` to GHCR with the version and `latest` tags. An operator verifies the downloaded executable before first use:

```sh
sha256sum --check SHA256SUMS
chmod 0755 ./dans_v1.0.0_linux_amd64
./dans_v1.0.0_linux_amd64 version
```

Build and publish the same command surface as a multi-platform OCI image:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=v1.0.0 \
  --tag ghcr.io/ncode/dans:v1.0.0 \
  --push .
```

The final image is `scratch`-based, contains only the static executable and CA roots, and defaults to UID/GID 65532 with `dans serve`. Supplying another command runs maintenance or CLI workflows from that same artifact.

Before publishing, exercise each platform independently. The smoke check asserts the image platform, numeric non-root user, embedded version, offline help, maintenance command surface, and a 26-MiB unpacked container-root-filesystem ceiling through `SizeRootFs` (rather than backend-dependent packed image `.Size`):

```sh
scripts/oci-smoke.sh dans-release-smoke linux/amd64 v1.0.0
scripts/oci-smoke.sh dans-release-smoke linux/arm64 v1.0.0
```

Release publication does not replace the complete verification baseline in OpenSpec task 12.6; generation, unit, race, static, integration, and contract gates must also pass.

The evidence-backed artifact, startup, ready-idle memory, and representative request-path measurements are recorded in the [performance and resource baseline](../openspec/changes/archive/2026-08-17-build-dans-v1/evidence/performance/README.md). CI runs portable and real-PostgreSQL benchmark correctness smoke but deliberately does not hard-gate shared-runner `ns/op` values.

## First release checklist

The prepared [v1.0.0 release notes](releases/v1.0.0.md) and [artifact rehearsal](releases/v1.0.0-verification.md) describe the candidate. The rehearsal does not publish a tag, GitHub release, or registry image.

1. Merge the readiness changes and require all CI checks on that exact main commit to pass. Confirm the chosen version has no existing tag or release and review the release notes, supported dependencies, and operations runbooks.
2. Rehearse with Node.js 24 and the pinned Go toolchain. Keep candidate artifacts and raw logs in private storage:

   ```sh
   export GOTOOLCHAIN=go1.26.5
   scripts/release_workflow_test.sh
   scripts/release_test.sh
   scripts/release.sh build v1.0.0 dist/v1.0.0
   scripts/release.sh verify dist/v1.0.0
   scripts/oci-smoke.sh dans-release-smoke linux/amd64 v1.0.0
   scripts/oci-smoke.sh dans-release-smoke linux/arm64 v1.0.0
   ```

3. When the candidate is approved for publication, tag the verified main commit and push that version tag. The release workflow rebuilds from the tagged source, checks both platforms, pushes the versioned and `latest` images, and creates the GitHub release with generated notes.
4. Apply the reviewed first-release notes to the published release:

   ```sh
   gh release edit v1.0.0 --notes-file docs/releases/v1.0.0.md
   ```

5. Download the published executables and checksum manifest into a fresh directory, verify their checksums and `version` output on each target architecture, and pull the versioned image for both platforms. Recheck image platform, UID/GID, `version`, `help`, and `db migrate --help`. Record the published image digest and use that digest when pinning an installation.

Publication remains unverified until those downloaded and pulled artifacts pass. A local build does not establish registry access, release permissions, or the integrity of a later workflow build. If publication fails after pushing an image, inspect the existing tag, release, and package state before retrying; do not replace a version tag or assume nothing was published.
