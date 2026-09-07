# Shared wasm-opt recipe and activation budgets for the engine deploy artifact.
# Source this file; do not execute it.
#
# The optimised artifact is reproducible only if the Binaryen version AND the flag list match
# exactly, and the budgets below decide whether it can be deployed at all, so both live here and
# every consumer reads them from here — a recipe or a limit that drifts between the build script
# and the CI gate produces an artifact no gate has actually checked.

BINARYEN_VERSION="version_119"

# The flags are load-bearing beyond size:
#   -Oz                                          size-first optimisation
#   --one-caller-inline-max-function-size 200    cap the inlining of single-use callees. Binaryen's
#                                                -Oz default folds most of the contract into the
#                                                SDK router and emits one function body past the
#                                                per-function opcode budget, which fails activation
#                                                even though the module is inside the size budget.
#                                                200 sits in the flat basin of a measured sweep;
#                                                the exact minimum shifts with the sources and is
#                                                not worth chasing.
#   --enable-bulk-memory                         not optional: the compiler already emits
#                                                bulk-memory instructions and wasm-opt refuses the
#                                                input without it.
#   the remaining --enable-*                     the rest of the feature set the module uses.
WASM_OPT_FLAGS=(
    -Oz
    --one-caller-inline-max-function-size 200
    --enable-bulk-memory
    --enable-sign-ext
    --enable-mutable-globals
    --enable-nontrapping-float-to-int
    --enable-reference-types
)

# Activation enforces two independent budgets, and a module that clears one can fail the other.
#
# Size: MaxWasmSize applies to the DECOMPRESSED module as submitted, which is the optimised
# artifact plus the `project_hash` custom section cargo-stylus appends (measured at 47 bytes;
# rounded up below). 262144 is the ArbOS 60 value, confirmed against Arbitrum Sepolia: builds of
# this engine at 272,003 B and 277,107 B are rejected, and the boundary sits on 256 KiB. Do not
# raise it from a historical number — re-measure with `cargo stylus check` against a live RPC.
STYLUS_MAX_WASM_SIZE=262144
DEPLOY_SECTION_OVERHEAD=64
ACTIVATION_SAFETY_MARGIN=1024
OPT_SIZE_LIMIT=$((STYLUS_MAX_WASM_SIZE - DEPLOY_SECTION_OVERHEAD - ACTIVATION_SAFETY_MARGIN))

# Opcodes: no single function body may carry more than this many.
STYLUS_MAX_FUNC_OPCODES=65536

# Echo the path to a wasm-opt whose version is exactly BINARYEN_VERSION, downloading it into $1
# when the one on PATH is missing or a different version — any other version emits different
# bytes. ANCHORED match ("wasm-opt version 119 (...)"): a bare substring would false-accept a
# build whose version line merely contains the digits (git-describe suffixes, version 1190).
resolve_wasm_opt() {
    local workdir="$1" wopt tarball
    wopt="$(command -v wasm-opt || true)"
    if [ -n "$wopt" ] && "$wopt" --version 2>/dev/null | grep -qE "^wasm-opt version ${BINARYEN_VERSION#version_}( |\$)"; then
        echo "$wopt"
        return 0
    fi
    tarball="$workdir/binaryen.tar.gz"
    curl -fsSL -o "$tarball" \
        "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz" || return 1
    tar xzf "$tarball" -C "$workdir" || return 1
    echo "$workdir/binaryen-${BINARYEN_VERSION}/bin/wasm-opt"
}
