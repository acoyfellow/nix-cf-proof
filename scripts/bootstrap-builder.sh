set -euo pipefail

: "${SOURCE_SHA:?}"

mkdir -p /work/src /nix /etc/nix /etc/ssl/certs
cd /work

node -e '
const tls = require("tls");
require("fs").writeFileSync("/etc/ssl/certs/ca-bundle.crt", tls.rootCertificates.join("\n"));
'

node -e '
const fs = require("fs");
async function download(url, path) {
  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok) throw new Error(`${url} ${response.status}`);
  fs.writeFileSync(path, Buffer.from(await response.arrayBuffer()));
  console.log(`downloaded ${response.url}`);
}
(async () => {
  await download(process.env.NIX_STATIC_URL, "/work/nix-static");
  await download(`https://codeload.github.com/acoyfellow/nix-cf-proof/tar.gz/${process.env.SOURCE_SHA}`, "/work/src.tar.gz");
})().catch((error) => { console.error(error); process.exit(1); });
'
chmod +x /work/nix-static
mkdir -p /work/bin
ln -sf /work/nix-static /work/bin/nix
ln -sf /work/nix-static /work/bin/nix-store
tar -xzf /work/src.tar.gz -C /work/src --strip-components=1
export PATH="/work/bin:$PATH"
nix --version
exec bash /work/src/scripts/builder.sh
