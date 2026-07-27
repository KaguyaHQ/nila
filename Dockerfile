# Multi-stage build for a Phoenix release.
#
# Base images are pinned to the same versions kaguya-api uses so the Hetzner
# box shares builder/runner layers across both apps.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags  (builder)
#   - https://hub.docker.com/_/debian              (runner)
#
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=bullseye-20260713-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

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

# runtime.exs is read at boot, not compile time — copy after compile
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# ---- runtime image -------------------------------------------------------
FROM ${RUNNER_IMAGE}

# Points the GHCR package at this repo (the package was first pushed from the
# now-archived nila-ops repo, which left the source link stale).
LABEL org.opencontainers.image.source="https://github.com/KaguyaHQ/nila"

# poppler-utils: `pdfinfo` counts a packet's pages before extraction windows it,
# `pdftocairo` renders those pages as the evidence a reviewer checks a line
# against (both Nila.Gst.Extraction.Windowed), and `pdftoppm` serves the
# benchmark adapter. Without it every purchase dump fails at the page count.
RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl xz-utils \
  poppler-utils fonts-dejavu-core fonts-noto-core fonts-noto-ui-core \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Typst renders quote/invoice PDFs (Nila.Typst). Pinned prebuilt binary — keep in
# sync with the version developers run locally. The Noto/DejaVu fonts above give it
# ₹ and Tamil glyph coverage; without them the engine emits tofu boxes.
ARG TYPST_VERSION="0.14.2"
RUN curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-x86_64-unknown-linux-musl.tar.xz" \
    | tar -xJ -C /usr/local/bin --strip-components=1 typst-x86_64-unknown-linux-musl/typst \
  && typst --version

# locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

# copy the assembled release from the builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/nila ./

RUN chmod +x /app/bin/server /app/bin/migrate

USER nobody

# Migrations run via `/app/bin/migrate` in deploy.sh before this starts.
CMD ["/app/bin/server"]
