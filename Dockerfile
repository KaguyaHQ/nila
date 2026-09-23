# Multi-stage build for a Phoenix release.
#
# Base images are pinned so local and production builds use the same toolchain.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags  (builder)
#   - https://hub.docker.com/_/debian              (runner)
#
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=bookworm-20260713-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
# Match the builder's Debian family, with Python >=3.10 for native PDF tables.
ARG RUNNER_IMAGE="python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84"

FROM node:22-bookworm-slim AS frontend
WORKDIR /app/frontend
COPY frontend/package.json frontend/pnpm-lock.yaml frontend/pnpm-workspace.yaml ./
RUN npm install --global $(node -p "require('./package.json').packageManager") \
    && pnpm install --frozen-lockfile
COPY frontend/ ./
COPY priv/openapi/ /app/priv/openapi/
COPY assets/js/hooks/pdf_viewer.js /app/assets/js/hooks/pdf_viewer.js
COPY assets/vendor/pdfjs/ /app/assets/vendor/pdfjs/
RUN pnpm run build

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies. No Node/npm: assets are built by the esbuild and
# tailwind Elixir wrappers, which download their own standalone binaries.
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config before compiling deps so a config change busts the
# dependency compile cache
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib

RUN mix compile

# build minified, digested assets (tailwind + esbuild + phx.digest)
RUN mix assets.deploy
COPY --from=frontend /app/priv/static/frontend ./priv/static/frontend

# runtime.exs is read at boot, not compile time — copy after compile
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# ---- runtime image -------------------------------------------------------
FROM ${RUNNER_IMAGE}

# Points the GHCR package at this repo (the package was first pushed from the
# now-archived nila-ops repo, which left the source link stale).
LABEL org.opencontainers.image.source="https://github.com/KaguyaHQ/nila"

# poppler-utils: `pdftocairo` renders packet pages as the evidence a reviewer
# checks against, while `pdfinfo` and `pdftoppm` serve eval and benchmark tools.
# Without it extracted dumps cannot carry review evidence.
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  poppler-utils fonts-dejavu-core fonts-noto-core fonts-noto-ui-core xz-utils \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Typst compiles the bundled invoice template; no Node or browser runtime needed.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      arm64) TYPST_ARCH=aarch64; TYPST_SHA=491b101aa40a3a7ea82a3f8a6232cabb4e6a7e233810082e5ac812d43fdcd47a ;; \
      amd64) TYPST_ARCH=x86_64; TYPST_SHA=a6044cbad2a954deb921167e257e120ac0a16b20339ec01121194ff9d394996d ;; \
      *) exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v0.14.2/typst-${TYPST_ARCH}-unknown-linux-musl.tar.xz" -o /tmp/typst.tar.xz \
    && echo "${TYPST_SHA}  /tmp/typst.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/typst.tar.xz -C /usr/local/bin --strip-components=1 "typst-${TYPST_ARCH}-unknown-linux-musl/typst" \
    && rm /tmp/typst.tar.xz \
    && typst --version

# locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

COPY priv/python/requirements.txt /tmp/invoice-requirements.txt
RUN python -m pip install --no-cache-dir --only-binary=:all: -r /tmp/invoice-requirements.txt \
    && python -c "import pymupdf; assert pymupdf.VersionBind == '1.28.2'"

ENV MIX_ENV="prod"

# copy the assembled release from the builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/nila ./

RUN chmod +x /app/bin/server /app/bin/migrate

USER nobody

# Migrations run via `/app/bin/migrate` in deploy.sh before this starts.
CMD ["/app/bin/server"]
