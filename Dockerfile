# syntax=docker/dockerfile:1@sha256:ac85f380a63b13dfcefa89046420e1781752bab202122f8f50032edf31be0021

# ビルド時に基礎として使うイメージを定義
FROM buildpack-deps:bookworm as base-build
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
# jqのバイナリを取得する => /jq
FROM ghcr.io/jqlang/jq:1.7 as fetch-jq

# 音声モデルを取得する => /app/
FROM --platform=$BUILDPLATFORM base-build AS model-fetch
WORKDIR /app
RUN wget https://github.com/jpreprocess/jpreprocess/releases/download/v0.6.1/naist-jdic-jpreprocess.tar.gz \
    && tar xzf naist-jdic-jpreprocess.tar.gz \
    && rm naist-jdic-jpreprocess.tar.gz
RUN git clone --depth 1 https://github.com/icn-lab/htsvoice-tohoku-f01.git

# pnpmを取得する => /pnpm/
FROM base-build as fetch-pnpm
ENV SHELL="sh"
ENV ENV="/tmp/env"
WORKDIR /dist
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,from=fetch-jq,source=/jq,target=/mounted-bin/jq \
    curl -fsSL --compressed https://get.pnpm.io/install.sh | env PNPM_VERSION=$(cat package.json  | /mounted-bin/jq -r .packageManager | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') sh -

# .npmrcに設定を追記する => /.npmrc
FROM base-build as change-npmrc
COPY --link .npmrc ./
RUN --mount=type=bind,source=.node-version,target=.node-version \
    echo "store-dir=/.pnpm-store" >> .npmrc &&\
    echo "use-node-version=`cat .node-version`" >> .npmrc
     
# Node.jsと依存パッケージを取得する => /pnpm/,/.pnpm-store
FROM base-build as fetch-deps
COPY --link --from=fetch-pnpm /pnpm/ /pnpm/
RUN --mount=type=cache,target=/.pnpm-store \
    --mount=type=bind,from=change-npmrc,source=/.npmrc,target=.npmrc \
    --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=pnpm-lock.yaml,target=pnpm-lock.yaml \
    pnpm fetch

# dev用の依存パッケージをインストールする => /node_modules/
FROM --platform=$BUILDPLATFORM base-build as dev-deps
RUN --mount=type=cache,target=/.pnpm-store \
    --mount=type=bind,from=fetch-deps,source=/pnpm/,target=/pnpm/ \
    --mount=type=bind,from=change-npmrc,source=/.npmrc,target=.npmrc \
    --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=pnpm-lock.yaml,target=pnpm-lock.yaml \
    pnpm install --frozen-lockfile --offline

# ビルドする => /dist/
FROM --platform=$BUILDPLATFORM base-build as builder
RUN --mount=type=bind,from=fetch-deps,source=/pnpm/,target=/pnpm/ \
    --mount=type=bind,from=dev-deps,source=/node_modules/,target=node_modules/ \
    --mount=type=bind,from=change-npmrc,source=/.npmrc,target=.npmrc \
    --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=build.js,target=build.js \
    --mount=type=bind,source=src/,target=src/ \
    pnpm build

# prod用の依存パッケージをインストールする => /node_modules/
FROM base-build as prod-deps
ARG NODE_ENV="production"
RUN --mount=type=cache,target=/.pnpm-store \
    --mount=type=bind,from=fetch-deps,source=/pnpm/,target=/pnpm/ \
    --mount=type=bind,from=change-npmrc,source=/.npmrc,target=.npmrc \
    --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=pnpm-lock.yaml,target=pnpm-lock.yaml \
    pnpm install --frozen-lockfile --offline

FROM gcr.io/distroless/cc-debian12:nonroot as runner
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV NODE_ENV="production"
WORKDIR /app
COPY --link --from=model-fetch /app/ ./model/
COPY --link --from=fetch-deps /pnpm/ /pnpm/
COPY --link --from=builder /dist/ ./dist/
COPY --from=prod-deps /node_modules/ ./node_modules/
COPY --link --from=change-npmrc /.npmrc ./
COPY --link package.json ./
ENTRYPOINT [ "pnpm", "--shell-emulator" ]
CMD [ "start" ]
