#!/bin/bash
set -e

export $(cat .env | xargs)

SRC=$(dirname $0)
SRC=$(realpath "$SRC")

echo "Building docker image"
docker build \
    -t emception_build \
    --build-arg EMSCRIPTEN_VERSION=$EMSCRIPTEN_VERSION \
    --build-arg LLVM_COMMIT=$LLVM_COMMIT \
    --build-arg BINARYEN_COMMIT=$BINARYEN_COMMIT \
    --build-arg CPYTHON_COMMIT=$CPYTHON_COMMIT \
    --build-arg QUICKJSPP_COMMIT=$QUICKJSPP_COMMIT \
    --build-arg BROTLI_COMMIT=$BROTLI_COMMIT \
    --build-arg NODE_MAJOR=$NODE_MAJOR \
    --progress plain \
    .

id=$(docker create emception_build)
docker cp $id:/home/builder/src ./out
docker rm -v $id

# mkdir -p $(pwd)/build/emsdk_cache

# docker run \
#     -i --rm \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v $(pwd):$(pwd) \
#     -v $(pwd)/build/emsdk_cache:/emsdk/upstream/emscripten/cache \
#     emception_build \
#     bash -c "cd $(pwd) && ./build.sh"

# ./build-demo.sh