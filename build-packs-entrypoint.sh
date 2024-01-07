#!/bin/bash

set -e

BUILD="$1"

echo "compressing packs"
EXT=".pack"
if [ "$EMCEPTION_NO_COMPRESS" != "1" ]; then
    # Use brotli compressed packages
    EXT=".pack.br"
    for PACK in $BUILD/packages/*.pack; do
        PACK=$(basename $PACK .pack)
        echo ${PACK}
        brotli --best --keep $BUILD/packages/$PACK.pack
    done
fi

IMPORTS=""
EXPORTS=""
for PACK in $BUILD/packages/*.pack; do
    PACK=$(basename $PACK .pack)
    NAME=$(echo $PACK | sed 's/[^a-zA-Z0-9_]/_/g')
    IMPORTS=$(printf \
        "%s\nimport %s from \"./packages/%s\";" \
        "$IMPORTS" "$NAME" "$PACK$EXT" \
    )
    EXPORTS=$(printf \
        "%s\n    \"%s\": %s," \
        "$EXPORTS" "$PACK" "$NAME" \
    )
done
printf '%s\nexport default {%s\n};' "$IMPORTS" "$EXPORTS" > "$BUILD/packs.mjs"
