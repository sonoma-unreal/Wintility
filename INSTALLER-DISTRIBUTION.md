# Installer distribution

Wintility's remote bootstrapper is maintained at the repository root in `install.ps1` and is published at:

- Production installer: https://wintility.pages.dev/install.ps1
- GitHub source: https://github.com/sonoma-unreal/Wintility/blob/main/install.ps1

## Quick start

In PowerShell:

```powershell
irm https://wintility.pages.dev/install.ps1 | iex
```

This command downloads and executes the response from the URL. Review the source before running it. The bootstrapper verifies the SHA-256 hash of the pinned release launcher before starting that launcher, but this check does **not** independently authenticate the bootstrapper itself before PowerShell executes it. Treat the hosted endpoint and repository permissions as security-sensitive.

## Cloudflare Pages deployment

The Pages project is named `wintility` and uses Direct Upload. Direct Upload projects cannot be converted to the Git-integration deployment mode, but they can be deployed by Wrangler in a CI workflow.

The workflow at `.github/workflows/deploy-pages.yml` copies only `install.ps1` into a clean output directory and deploys that directory. It does not publish the rest of the repository.

Configure these GitHub Actions repository secrets before expecting automated deployment to succeed:

- `CLOUDFLARE_API_TOKEN`: a Cloudflare API token with the permissions needed to deploy to Pages.
- `CLOUDFLARE_ACCOUNT_ID`: the Cloudflare account ID that owns the `wintility` Pages project.

After the workflow is merged, pushes to `main` that change `install.ps1` (or the workflow itself) trigger a deployment. A manual run is also available through the Actions tab. Until both secrets are configured and the workflow succeeds, upload the single `install.ps1` file manually to the existing Pages project.

## Release pinning

When updating the bootstrapper, update the pinned release version and expected SHA-256 together. Confirm the release asset's hash independently before changing the expected value. Do not point the bootstrapper at a mutable `latest` asset without a deliberate change to the verification design.
