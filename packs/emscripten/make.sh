#!/bin/bash

set -e

if [ -d emscripten ]; then
    # nothing to do here
    exit
fi

SRC=$(dirname $0)
SRC=$(realpath "$SRC")

curl --output emscripten.zip --location https://github.com/emscripten-core/emscripten/archive/refs/tags/$EMSCRIPTEN_VERSION.zip
unzip -q emscripten.zip
rm emscripten.zip
mv emscripten-* emscripten

pushd emscripten/

cp $SRC/config ./.emscripten

# We won't support closure-compiler, remove it from the dependencies
cat package.json \
    | jq '. | del(.dependencies["google-closure-compiler"])' \
    | jq '. | del(.dependencies["html-minifier-terser"])' \
    > _package.json
mv _package.json package.json

# Patch emscripten to:
# * avoid invalidating the cache
# * fix a bug with proxy_to_worker
patch -p2 < $SRC/emscripten.patch

# Install dependencies (but nor development dependencies)
npm i --production

# Remove a bunch of things we won't use
rm -Rf \
    ./.circleci \
    ./.github \
    ./cmake \
    ./site \
    ./test \
    ./third_party/closure-compiler \
    ./third_party/jni \
    ./third_party/ply \
    ./third_party/websockify \
    ./tools/websocket_to_posix_proxy \
    ./*.bat \
    ./cache/build
# remove "cache/build" to avoid dealing with empty directories

cp -R /emsdk/upstream/emscripten/cache ./cache

popd

echo "split_packages:"
node "$SRC/split_packages.js" | bash
