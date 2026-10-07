# Blockers

## Finding: Cloudflare rejects dockerTools.buildLayeredImage output (2026-10-07)

Image preparation (`POST /containers/image-preparations`) returns `pending` with reason `runtime image build failed` for every `buildLayeredImage` image. Wrangler shows only `pending` and times out after 15 minutes.

| Image | Builder | Result |
| --- | --- | --- |
| busybox from Docker Hub (Docker v2) | skopeo | ready |
| busybox from Docker Hub (OCI) | skopeo | ready |
| busybox, `dockerTools.buildImage` (single layer) | Nix | ready |
| busybox, `dockerTools.buildLayeredImage` | Nix | runtime image build failed |
| same, OCI format | Nix | runtime image build failed |
| nix-cf-proof, `buildLayeredImage`, 100 layers | Nix | runtime image build failed |

Fix applied: devenv.nix uses `dockerTools.buildImage`. Report upstream to the Containers team, with this table.


## 1. GitHub app access to acoyfellow/nix-cf-proof (open)

- Tick 1: OAuth authorize succeeded (redirect returned a code to dash.cloudflare.com).
- The dashboard Connect sheet no longer opens after the redirect, even after reload.
- The app is installed on acoyfellow (GitHub settings/installations lists Cloudflare Workers and Pages).
- Repo access cannot be checked: GitHub asks for sudo-mode passkey confirmation.
- Action for Jordan: open github.com/settings/installations, Configure Cloudflare Workers and Pages, add nix-cf-proof. Then in the Worker settings, Builds, Connect: account acoyfellow, repo nix-cf-proof, branch main, build `npm run build`, deploy `npx wrangler deploy`.

### Original notes

- Workers Builds needs the "Cloudflare Workers and Pages" GitHub app on `acoyfellow`.
- The dashboard Git account list has `coeyman`, not `acoyfellow`.
- GitHub keeps the Authorize button disabled for scripted clicks. This is a GitHub anti-clickjacking control. Do not bypass it.
- Action for Jordan: in the open cmux browser tab, click **Authorize**, then install the app for **only** `acoyfellow/nix-cf-proof`.
- After that, the loop sets: build command `npm run build`, deploy command `npx wrangler deploy`, branch `main`.

## 2. No local Nix (by design)

- `/nix` does not exist. Gate check "local devenv shell" needs Nix + devenv on the Mac.
- Installing Nix needs `sudo` (creates `/nix` volume). Agent cannot enter the password.
- Action for Jordan: `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`, then `nix profile add github:cachix/devenv/v2.4.0`.
