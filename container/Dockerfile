FROM nixos/nix:2.35.2 AS build
COPY container/nix.conf /tmp/nix-extra.conf
RUN cat /tmp/nix-extra.conf >> /etc/nix/nix.conf
RUN nix profile add github:cachix/devenv/v2.4.0
WORKDIR /src
COPY devenv.nix devenv.yaml devenv.lock ./
COPY nix ./nix
COPY scripts ./scripts
RUN devenv build outputs.sandbox outputs.git outputs.nixos > /tmp/build.json && cat /tmp/build.json
COPY container/assemble.sh /tmp/assemble.sh
COPY container/ci.env /tmp/ci.env
RUN sh /tmp/assemble.sh

FROM scratch
COPY --from=build /out/ /
ENV PATH=/sandbox/bin
ENV HOME=/tmp
ENV SSL_CERT_FILE=/sandbox/etc/ssl/certs/ca-bundle.crt
CMD ["/sandbox/bin/sleep", "infinity"]
