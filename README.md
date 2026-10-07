# nix-cf-proof

One `devenv.nix` defines a patched `git` that refuses every force push. The same definition runs in two places:

- your shell, through `devenv shell`
- a Cloudflare Container, built by Workers Builds from `container/Dockerfile`

A second Container starts the NixOS system closure with `/init` as the entrypoint. It records whether systemd boots.

The git patches come from [ghuntley/nix-demo](https://github.com/ghuntley/nix-demo).

## Run the proof

```sh
./proof.sh
```

The script exits 0 only when all of these are true:

1. Workers Builds built the image. The build receipt contains a Workers Builds UUID.
2. The container git has the same version and overlay patch hash as your local devenv git.
3. The container git store path matches the store path that the Cloudflare build produced.
4. Every force push form fails, both locally and in the container.
5. The systemd result is recorded, with its log, in `receipts/container-systemd.json`.

## Build path

Workers Builds runs `npm run build`, then `npx wrangler deploy`. Wrangler builds `container/Dockerfile` on Cloudflare. The Dockerfile starts from `nixos/nix`, installs devenv, runs `devenv build`, and copies the Nix closure into a `scratch` image.
