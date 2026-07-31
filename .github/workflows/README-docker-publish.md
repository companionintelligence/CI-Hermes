# Docker Publish Workflow Setup

This repository publishes container images with:
- workflow file: `.github/workflows/docker-publish.yml`
- image registry: `ghcr.io`
- tags pushed: release tag only

## Cut a Release (runbook)

End-to-end steps to ship a new version of CI-Hermes and point the marketplace at it.
Tags are date-based with a `v` prefix: `vYYYY.M.D` (e.g. `v2026.6.20`). Use
`vYYYY.M.D.N` for a second release on the same day (e.g. `v2026.6.20.2`).

1. **Tag the release** from an up-to-date `master` — the tag push triggers the build:
   ```bash
   git fetch origin
   git tag v2026.6.20 origin/master    # tag the commit you want to ship
   git push origin v2026.6.20
   ```
2. **Watch the build** in `Actions` → `Docker Build and Push` for the tag. It builds
   multi-arch (`amd64`/`arm64`), pushes
   `ghcr.io/companionintelligence/ci-hermes:<TAG>`, and publishes a GitHub Release.
   Wait for it to go green before step 3 (the marketplace must not point at an image
   that does not exist yet).
3. **Bump the marketplace** in `CI-Marketplace` so the appliance installs the new image:
   - `apps/ci-hermes/config.json` → set `"version": "<TAG>"` (keep the `v` prefix) and
     `"updated_at"` to the current time in **epoch milliseconds**
     (`echo "$(date +%s)000"`).
   - `apps/ci-hermes/docker-compose.json` → set **both** `image:` tags (the `ci-hermes`
     web service and the `ci-hermes-gateway` service) to
     `ghcr.io/companionintelligence/ci-hermes:<TAG>`.
   - Validate: `bun test && bun run scripts/audit-apps.ts` (expect `ERR=0` and no new
     `ci-hermes` findings).
   - Open a PR against the marketplace default branch (`dev`) and merge it once the
     image from step 2 is published.
4. **Deploy the catalog.** The `Deploy App Catalog` workflow runs on push to **`main`**,
   *not* on `dev` merges — so merging to `dev` alone does not publish anything. After
   the PR lands on `dev`, fast-forward `main` to it and push:
   ```bash
   git push origin origin/dev:main
   ```
   That triggers the deploy (ships every valid `config.json` to R2/D1, then
   `reconcile.js` prunes). CI-Hub picks up the new version on its next hourly pull of
   `/api/store`.

> The marketplace `version` and the image tag for **ci-hermes** both carry the `v`
> prefix and must match exactly. (ci-openclaw uses the un-prefixed form — see its
> own README-docker-publish.md.)

## What The Workflow Does

The workflow runs when:
- a git tag is pushed
- the `Tag CI-Hermes Version On Merge` workflow completes successfully

It builds multi-arch images (`linux/amd64`, `linux/arm64`) and pushes:
- `${IMAGE_NAME}:${TAG}`

For tag-push runs, it also creates or updates a published GitHub Release for `${TAG}`.

## Required GitHub Settings

### 1) Repository Action Permissions

In GitHub repository settings:
- `Settings` -> `Actions` -> `General`
- Ensure actions are enabled.
- Under workflow permissions, allow write access to packages.

The workflow itself already requests:
- `contents: write`
- `packages: write`

### 2) Repository Variables

Set these in:
- `Settings` -> `Secrets and variables` -> `Actions` -> `Variables`

Optional variables:
- `IMAGE_NAME`
  - Default: `ghcr.io/${{ github.repository }}`
  - Recommended value: `ghcr.io/companionintelligence/ci-hermes`

### 3) Repository Secrets

No custom secret is required for same-repo GHCR publishing.

The workflow uses the default `GITHUB_TOKEN` for `docker login ghcr.io`.

## Quick Verification

> **Do not push a throwaway tag to test this workflow.** This section used to say to
> push `test-publish-1`. That built and pushed a real image to GHCR and created a
> public GitHub Release named after the test tag — there is no dry-run path, so a
> "test" publish is a real publish. The workflow now only triggers on `v[0-9]*`, so a
> tag like `test-publish-1` does nothing at all.

Verify against a real release instead, as part of cutting one:

1. Cut a release following the runbook above.
2. Watch the `Docker Build and Push` run in Actions for that tag.
3. Verify the image tag in GitHub Packages matches the release tag.
4. Verify a published release exists in the Releases tab for the same tag.

If you need to re-run a build for a tag that already exists, re-run the failed job
from the Actions UI rather than pushing a new tag.

## Notes

- If this repository is moved/forked, set `IMAGE_NAME` explicitly.
