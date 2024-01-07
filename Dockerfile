# This is the last tested version of emscripten.
# Feel free to try with a newer version
ARG EMSCRIPTEN_VERSION=latest

FROM ubuntu:jammy AS base

RUN apt-get -qq -y update
RUN DEBIAN_FRONTEND="noninteractive" TZ="America/San_Francisco" apt-get -qq install -y --no-install-recommends \
        git \
        ca-certificates \
        build-essential \
        cmake \
        make \
        ninja-build \
        git-lfs \
        python3 \
        python3-pip

FROM base AS emscripten_build

ARG EMSCRIPTEN_VERSION=latest
ENV EMSDK /emsdk

# ------------------------------------------------------------------------------

RUN echo "## Start building" \
    && echo "## Update and install packages" \
    && apt-get -qq install -y --no-install-recommends \
        binutils \
        file \
    && echo "## Done"

# Copy the contents of the emsdk repository to the container
RUN git clone https://github.com/emscripten-core/emsdk.git ${EMSDK}

RUN echo "## Install Emscripten" \
    && cd ${EMSDK} \
    && ./emsdk install ${EMSCRIPTEN_VERSION} \
    && echo "## Done"

# This generates configuration that contains all valid paths according to installed SDK
# TODO(sbc): We should be able to use just emcc -v here but it doesn't
# currently create the sanity file.
RUN cd ${EMSDK} \
    && echo "## Generate standard configuration" \
    && ./emsdk activate ${EMSCRIPTEN_VERSION} \
    && chmod 777 ${EMSDK}/upstream/emscripten \
    && chmod -R 777 ${EMSDK}/upstream/emscripten/cache \
    && echo "int main() { return 0; }" > hello.c \
    && ${EMSDK}/upstream/emscripten/emcc -c hello.c \
    && cat ${EMSDK}/upstream/emscripten/cache/sanity.txt \
    && echo "## Done"

# Cleanup Emscripten installation and strip some symbols
RUN echo "## Aggressive optimization: Remove debug symbols" \
    && cd ${EMSDK} && . ./emsdk_env.sh \
    # Remove debugging symbols from embedded node (extra 7MB)
    && strip -s `which node` \
    # Tests consume ~80MB disc space
    && rm -fr ${EMSDK}/upstream/emscripten/tests \
    # strip out symbols from clang (~extra 50MB disc space)
    && find ${EMSDK}/upstream/bin -type f -exec strip -s {} + || true \
    && echo "## Done"

# ------------------------------------------------------------------------------
# -------------------------------- STAGE DEPLOY --------------------------------
# ------------------------------------------------------------------------------

FROM base AS emception_base

COPY --from=emscripten_build /emsdk /emsdk

# These fallback environment variables are intended for situations where the
# entrypoint is not utilized (as in a derived image) or overridden (e.g. when
# using `--entrypoint /bin/bash` in CLI).
# This corresponds to the env variables set during: `source ./emsdk_env.sh`
ENV EMSDK=/emsdk \
    PATH="/emsdk:/emsdk/upstream/emscripten:/emsdk/node/16.20.0_64bit/bin:${PATH}"

# ------------------------------------------------------------------------------
# Create a 'standard` 1000:1000 user
# Thanks to that this image can be executed as non-root user and created files
# will not require root access level on host machine Please note that this
# solution even if widely spread (i.e. Node.js uses it) is far from perfect as
# user 1000:1000 might not exist on host machine, and in this case running any
# docker image will cause other random problems (mostly due `$HOME` pointing to
# `/`)
#RUN echo "## Create emscripten user (1000:1000)" \
#    && groupadd --gid 1000 emscripten \
#    && useradd --uid 1000 --gid emscripten --shell /bin/bash --create-home emscripten \
#    && echo "## Done"

# ------------------------------------------------------------------------------

RUN echo "## Update and install packages" \
    # Somewhere in here apt sets up tzdata which asks for your time zone and blocks
    # waiting for the answer which you can't give as docker build doesn't read from
    # the terninal. The env vars set here avoid the interactive prompt and set the TZ.
    && DEBIAN_FRONTEND="noninteractive" TZ="America/San_Francisco" apt-get -qq install -y --no-install-recommends \
        sudo \
        libxml2 \
        wget \
        zip \
        unzip \
        ssh-client \
        ant \
        libidn12 \
        openjdk-11-jre-headless \
        pkg-config \
        jq \
        brotli \
        autoconf \
        autoconf-archive \
        automake \
        zlib1g-dev \
        libssl-dev \
        curl \
        gnupg \
        g++ \
    # Standard Cleanup on Debian images
    && apt-get -y clean \
    && apt-get -y autoclean \
    && apt-get -y autoremove \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/cache/debconf/*-old \
    && rm -rf /usr/share/doc/* \
    && rm -rf /usr/share/man/?? \
    && rm -rf /usr/share/man/??_* \
    && echo "## Done"

# Add to PATH the clang version that ships with emsdk
ENV PATH="${EMSDK}/upstream/bin:${PATH}"

# When running the contianer with a custom user/group, we need to provide that user with
# access to ~/.npm (in this case, /.npm).
# The easiest is to give access to everyone.
RUN mkdir -p /.npm && chmod a+rwx /.npm

WORKDIR /home/builder

COPY ./tooling/wasm-transform/wasm-transform.sh ./build/tooling/
COPY ./tooling/wasm-transform/codegen.sh ./build/tooling/
COPY ./tooling/wasm-transform/merge_codegen.sh ./build/tooling/

COPY ./tooling/wasm-transform/wasm-transform.cpp ./wasm-transform/
COPY ./tooling/wasm-package/wasm-package.cpp ./wasm-package/
COPY ./tooling/wasm-utils ./wasm-utils

RUN clang++ -O3 -I./wasm-utils -std=c++20 ./wasm-utils/*.cpp ./wasm-transform/wasm-transform.cpp -o ./build/tooling/wasm-transform

RUN clang++ -O3 -I./wasm-utils -std=c++20 ./wasm-utils/*.cpp ./wasm-package/wasm-package.cpp -o ./build/tooling/wasm-package

COPY ./emlib/ ./emlib

RUN mkdir -p ./build/wasm-package

RUN em++ \
    -s ALLOW_MEMORY_GROWTH=1 \
    -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
    -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
    -lproxyfs.js \
    --js-library=./emlib/fsroot.js \
    -lidbfs.js \
    -flto \
    -O3 \
    -I./wasm-utils -std=c++20 \
    ./wasm-utils/*.cpp \
    ./wasm-package/wasm-package.cpp \
    -o ./build/wasm-package/wasm-package.mjs

# Building LLVM
FROM base AS emception_prebuild_llvm

WORKDIR /home/builder

RUN git clone --depth 1 https://github.com/llvm/llvm-project.git ./upstream/llvm-project

ARG LLVM_COMMIT
WORKDIR /home/builder/upstream/llvm-project
RUN git fetch --depth=1 origin $LLVM_COMMIT
RUN git reset --hard $LLVM_COMMIT
WORKDIR /home/builder

COPY ./patches/llvm-project.patch ./patches/llvm-project.patch

WORKDIR /home/builder/upstream/llvm-project
RUN git apply ../../patches/llvm-project.patch
WORKDIR /home/builder/

# Configuring LLVM_NATIVE
RUN cmake -G Ninja \
        -S ./upstream/llvm-project/llvm/ \
        -B ./build/llvm-native/ \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=WebAssembly \
        -DLLVM_ENABLE_PROJECTS="clang"

RUN cmake --build ./build/llvm-native -- llvm-tblgen clang-tblgen

FROM emception_base AS emception_build_llvm

WORKDIR /home/builder

COPY --from=emception_prebuild_llvm /home/builder/upstream/llvm-project ./upstream/llvm-project
COPY --from=emception_prebuild_llvm /home/builder/build/llvm-native ./build/llvm-native

COPY ./emlib ./emlib

WORKDIR $EMSDK

# Configuring LLVM_BUILD
RUN . ${EMSDK}/emsdk_env.sh && \
    CXXFLAGS="-Dwait4=__syscall_wait4" \
    LDFLAGS="\
        -s LLD_REPORT_UNDEFINED=1 \
        -s ALLOW_MEMORY_GROWTH=1 \
        -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
        -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
        -lproxyfs.js \
        --js-library=/home/builder/emlib/fsroot.js \
    " emcmake cmake -G Ninja \
        -S /home/builder/upstream/llvm-project/llvm/ \
        -B /home/builder/build/llvm/ \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=WebAssembly \
        -DLLVM_ENABLE_PROJECTS="clang;lld;clang-tools-extra" \
        -DLLVM_ENABLE_DUMP=OFF \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_ENABLE_EXPENSIVE_CHECKS=OFF \
        -DLLVM_ENABLE_BACKTRACES=OFF \
        -DLLVM_BUILD_TOOLS=OFF \
        -DLLVM_ENABLE_THREADS=OFF \
        -DLLVM_BUILD_LLVM_DYLIB=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_TABLEGEN=/home/builder/build/llvm-native/bin/llvm-tblgen \
        -DCLANG_TABLEGEN=/home/builder/build/llvm-native/bin/clang-tblgen

WORKDIR /home/builder

# Patching build.ninja
# Make sure we build js modules (.mjs).
# The patch-ninja.sh script assumes that.
RUN sed -E 's/\.js/\.mjs/g' ./build/llvm/build.ninja > ./temp-build.ninja
RUN mv ./temp-build.ninja ./build/llvm/build.ninja

# The mjs patching is over zealous, and patches some source JS files rather than just output files.
# Undo that.
RUN sed -E 's/(pre|post|proxyfs|fsroot)\.mjs/\1.js/g' ./build/llvm/build.ninja > ./temp-build.ninja
RUN mv ./temp-build.ninja ./build/llvm/build.ninja

# fix wrong strange bug that generates 'ninja_required_version1.5' instead of 'ninja_required_version = 1.5'
RUN sed -E 's/ninja_required_version1\.5/ninja_required_version = 1.5/g' ./build/llvm/build.ninja > ./temp-build.ninja
RUN mv ./temp-build.ninja ./build/llvm/build.ninja

COPY ./patch-ninja.sh ./patch-ninja.sh

RUN ./patch-ninja.sh \
        ./build/llvm/build.ninja \
        llvm-box \
        ./build/tooling \
        clang lld llvm-nm llvm-ar llvm-objcopy llc \
        > ./temp-build.ninja

RUN cat ./temp-build.ninja >> ./build/llvm/build.ninja

# fix wrong strange bug that generates 'ninja_required_version1.5' instead of 'ninja_required_version = 1.5'
RUN sed -E 's/ninja_required_version1\.5/ninja_required_version = 1.5/g' ./build/llvm/build.ninja > ./temp-build.ninja
RUN mv ./temp-build.ninja ./build/llvm/build.ninja

COPY ./box_src/llvm-box.cpp ./box_src/llvm-box.cpp

WORKDIR $EMSDK

RUN . ${EMSDK}/emsdk_env.sh && \
    cmake --build /home/builder/build/llvm/ --parallel -- llvm-box

# ======================BINARYEN========================
FROM emception_base as emception_build_binaryen

WORKDIR /home/builder

RUN git clone --depth 1 https://github.com/WebAssembly/binaryen.git ./upstream/binaryen

ARG BINARYEN_COMMIT
WORKDIR /home/builder/upstream/binaryen
RUN git fetch --depth=1 origin $BINARYEN_COMMIT
RUN git reset --hard $BINARYEN_COMMIT
RUN git submodule init
RUN git submodule update
WORKDIR /home/builder

COPY ./emlib ./emlib

WORKDIR $EMSDK
RUN . ${EMSDK}/emsdk_env.sh && \
    LDFLAGS="\
        -s ALLOW_MEMORY_GROWTH=1 \
        -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
        -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
        -lproxyfs.js \
        --js-library=/home/builder/emlib/fsroot.js \
    " emcmake cmake -G Ninja \
        -S /home/builder/upstream/binaryen \
        -B /home/builder/build/binaryen \
        -DCMAKE_BUILD_TYPE=Release

# Binaryen likes to build single files, but that uses base64 and is less compressible.
# Make sure we build a separate wasm file
RUN sed -E 's/-s\s*SINGLE_FILE(=[^ ]*)?//g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

# Binaryen likes to build with -flto, which is great.
# However, LTO generates objects file with LLVM-IR bitcode rather than WebAssembly.
# The patching mechanism to generate binaryen-box only understands wasm object files.
# Because of that, we need to disable LTO.
RUN sed -E 's/-flto//g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

# Binaryen builds with NODERAWFS, which is not compatible with browser workflows.
# Disable it.
RUN sed -E 's/-s\s*NODERAWFS(\s*=\s*[^ ]*)?//g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

# Make sure we build js modules (.mjs).
# The patch-ninja.sh script assumes that.
RUN sed -E 's/\.js/.mjs/g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

# The mjs patching is over zealous, and patches some source JS files rather than just output files.
# Undo that.
RUN sed -E 's/\.mjs-/.js-/g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja
RUN sed -E 's/(pre|post|proxyfs|fsroot)\.mjs/\1.js/g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

# fix wrong strange bug that generates 'ninja_required_version1.5' instead of 'ninja_required_version = 1.5'
RUN sed -E 's/ninja_required_version1\.5/ninja_required_version = 1.5/g' /home/builder/build/binaryen/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/binaryen/build.ninja

WORKDIR /home/builder/
COPY ./patch-ninja.sh ./patch-ninja.sh

RUN ./patch-ninja.sh \
        /home/builder/build/binaryen/build.ninja \
        binaryen-box \
        /home/builder/build/tooling \
        wasm2js wasm-as wasm-ctor-eval wasm-emscripten-finalize wasm-metadce wasm-opt wasm-shell \
        > /tmp/build.ninja

RUN cat /tmp/build.ninja >> /home/builder/build/binaryen/build.ninja

COPY ./box_src/binaryen-box.cpp ./box_src/binaryen-box.cpp

WORKDIR $EMSDK
RUN . ${EMSDK}/emsdk_env.sh && \
    cmake --build /home/builder/build/binaryen/ -- binaryen-box

# ======================CPYTHON============================
FROM emception_base as emception_build_cpython

WORKDIR /home/builder

RUN git clone --depth 1 https://github.com/python/cpython.git ./upstream/cpython

ARG CPYTHON_COMMIT
WORKDIR /home/builder/upstream/cpython
RUN git fetch --depth=1 origin $CPYTHON_COMMIT
RUN git reset --hard $CPYTHON_COMMIT
COPY ./patches/cpython.patch /home/builder/cpython.patch
RUN git apply /home/builder/cpython.patch
RUN autoreconf -i

WORKDIR /home/builder/build/cpython-native

RUN /home/builder/upstream/cpython/configure  -C --host=x86_64-pc-linux-gnu --build=$(/home/builder/upstream/cpython/config.guess) --with-suffix=""
RUN make -j$(nproc)

WORKDIR /home/builder/upstream/cpython
RUN git reset --hard $CPYTHON_COMMIT
RUN git clean -f -d
RUN git apply /home/builder/cpython.patch
RUN autoreconf -i

WORKDIR /home/builder

COPY ./emlib ./emlib

WORKDIR $EMSDK

RUN mkdir -p /home/builder/build/cpython

# Build cpython with asyncify support.
# Disable sqlite3, zlib and bzip2, which cpython enables by default
RUN . ${EMSDK}/emsdk_env.sh && \
    cd /home/builder/build/cpython && \
    CONFIG_SITE=/home/builder/upstream/cpython/Tools/wasm/config.site-wasm32-emscripten \
    LIBSQLITE3_CFLAGS=" " \
    BZIP2_CFLAGS=" " \
    LDFLAGS="\
        -s ALLOW_MEMORY_GROWTH=1 \
        -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
        -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
        -lproxyfs.js \
        --js-library=/home/builder/emlib/fsroot.js \
    " emconfigure /home/builder/upstream/cpython/configure -C \
        --host=wasm32-unknown-emscripten \
        --build=$(/home/builder/upstream/cpython/config.guess) \
        --with-emscripten-target=browser \
        --disable-wasm-dynamic-linking \
        --with-suffix=".mjs" \
        --disable-wasm-preload \
        --enable-wasm-js-module \
        --with-build-python=/home/builder/build/cpython-native/python

RUN . ${EMSDK}/emsdk_env.sh && \
    cd /home/builder/build/cpython && \
    emmake make -j$(nproc)

WORKDIR /home/builder

COPY ./packs/cpython ./packs

RUN mkdir -p /home/builder/build/packs/

RUN ./packs/package.sh /home/builder/build

RUN mkdir -p /output/packages

RUN cp /home/builder/build/packs/*.pack /output/packages

# ==================QUICKNODE====================
FROM emception_base as emception_build_quicknode

WORKDIR /home/builder

COPY ./emlib ./emlib
COPY ./quicknode ./quicknode

ARG $QUICKJSPP_COMMIT
ENV QUICKJSPP_COMMIT=$QUICKJSPP_COMMIT

WORKDIR $EMSDK

RUN . ${EMSDK}/emsdk_env.sh && \
    CXXFLAGS=" \
        -fexceptions \
        -s DISABLE_EXCEPTION_CATCHING=0 \
    " \
    LDFLAGS="\
        -fexceptions \
        -s DISABLE_EXCEPTION_CATCHING=0 \
        -s ALLOW_MEMORY_GROWTH=1 \
        -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
        -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
        -lproxyfs.js \
        --js-library=/home/builder/emlib/fsroot.js \
    " emcmake cmake -G Ninja \
        -S /home/builder/quicknode/ \
        -B /home/builder/build/quicknode \
        -DCMAKE_BUILD_TYPE=Release

# Make sure we build js modules (.mjs).
# The patch-ninja.sh script assumes that.
RUN sed -E 's/quicknode\.js/quicknode\.mjs/g' /home/builder/build/quicknode/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/quicknode/build.ninja

RUN cmake --build /home/builder/build/quicknode/ -- quicknode

# ======================BROTLI=========================
FROM emception_base AS emception_build_brotli

WORKDIR /home/builder

RUN git clone --depth 1 https://github.com/google/brotli.git ./upstream/brotli

ARG BROTLI_COMMIT
WORKDIR /home/builder/upstream/brotli
RUN git fetch --depth=1 origin $BROTLI_COMMIT
RUN git reset --hard $BROTLI_COMMIT
WORKDIR /home/builder

COPY ./emlib ./emlib

WORKDIR $EMSDK

RUN . ${EMSDK}/emsdk_env.sh && \
    CFLAGS="-flto" \
    LDFLAGS="\
        -flto \
        -s ALLOW_MEMORY_GROWTH=1 \
        -s EXPORTED_FUNCTIONS=_main,_free,_malloc \
        -s EXPORTED_RUNTIME_METHODS=FS,PROXYFS,ERRNO_CODES,allocateUTF8 \
        -lproxyfs.js \
        --js-library=/home/builder/emlib/fsroot.js \
    " emcmake cmake -G Ninja \
        -S /home/builder/upstream/brotli/ \
        -B /home/builder/build/brotli/ \
        -DCMAKE_BUILD_TYPE=Release

# Make sure we build js modules (.mjs).
RUN sed -E 's/brotli\.js/brotli\.mjs/g' /home/builder/build/brotli/build.ninja > /tmp/build.ninja
RUN mv /tmp/build.ninja /home/builder/build/brotli/build.ninja

RUN cmake --build /home/builder/build/brotli/ -- brotli.mjs

# ================EMSCRIPTEN PACKS=========================
FROM emception_base as emception_build_emscripten_packs

RUN mkdir -p /etc/apt/keyrings
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

ARG NODE_MAJOR
ENV NODE_MAJOR=$NODE_MAJOR
RUN echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list

RUN apt-get -qq -y update

RUN DEBIAN_FRONTEND="noninteractive" TZ="America/San_Francisco" apt-get -qq install -y --no-install-recommends \
        nodejs

WORKDIR /home/builder

ARG EMSCRIPTEN_VERSION
ENV EMSCRIPTEN_VERSION=$EMSCRIPTEN_VERSION

COPY ./packs/emscripten ./packs

RUN ./packs/package.sh /home/builder/build

RUN mkdir -p /output/packages

RUN cp /home/builder/build/packs/*.pack /output/packages

# ===============BUILD WASM PACK==========
FROM emception_base AS emception_build_wasm_pack

WORKDIR /home/builder

COPY --from=emception_build_llvm /home/builder/build/llvm/bin/llvm-box.wasm .
COPY --from=emception_build_binaryen /home/builder/build/binaryen/bin/binaryen-box.wasm .
COPY --from=emception_build_cpython /home/builder/build/cpython/python.wasm .
COPY --from=emception_build_quicknode /home/builder/build/quicknode/quicknode.wasm .

RUN mkdir -p /output/packages

RUN /home/builder/build/tooling/wasm-package pack /output/packages/wasm.pack ./llvm-box.wasm ./binaryen-box.wasm ./python.wasm ./quicknode.wasm

# ===============OUTPUT===================
FROM base AS resulting

RUN apt-get -qq -y update
RUN DEBIAN_FRONTEND="noninteractive" TZ="America/San_Francisco" apt-get -qq install -y --no-install-recommends \
        brotli

WORKDIR /home/builder

COPY ./src ./src
COPY --from=emception_build_llvm /home/builder/build/llvm/bin/llvm-box.mjs ./src/llvm/
COPY --from=emception_build_binaryen /home/builder/build/binaryen/bin/binaryen-box.mjs ./src/binaryen/
COPY --from=emception_build_quicknode /home/builder/build/quicknode/quicknode.mjs ./src/quicknode/
COPY --from=emception_build_cpython /home/builder/build/cpython/python.mjs ./src/cpython/
COPY --from=emception_build_brotli /home/builder/build/brotli/brotli.mjs ./src/brotli/
COPY --from=emception_build_brotli /home/builder/build/brotli/brotli.wasm ./src/brotli/
COPY --from=emception_base /home/builder/build/wasm-package/wasm-package.mjs ./src/wasm-package/
COPY --from=emception_base /home/builder/build/wasm-package/wasm-package.wasm ./src/wasm-package/

# copy packs
COPY --from=emception_build_cpython /output/packages ./src/packages
COPY --from=emception_build_emscripten_packs /output/packages ./src/packages
COPY --from=emception_build_wasm_pack /output/packages ./src/packages

# build packs entrypoint
COPY ./build-packs-entrypoint.sh .
RUN ./build-packs-entrypoint.sh ./src/

RUN apt-get install tree 

RUN tree ./src
