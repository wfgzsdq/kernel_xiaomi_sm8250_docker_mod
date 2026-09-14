#!/usr/bin/env bash
# CI helpers for the unmodified upstream build.sh. Run from a disposable checkout.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

verify_config() {
    local config=${1:?Expected a resolved .config} line count=0 failed=0
    local -A seen=()
    test -s "$config"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^CONFIG_[A-Z0-9_]+=y$ ]]; then
            echo "Unsupported fragment entry: $line" >&2
            return 1
        fi
        if [[ -n ${seen[$line]:-} ]]; then
            echo "Duplicate fragment entry: $line" >&2
            return 1
        fi
        seen[$line]=1
        count=$((count + 1))
        if [[ $(grep -Fxc -- "$line" "$config" || true) != 1 ]]; then
            echo "ERROR: $config does not contain exactly one $line" >&2
            failed=1
        fi
    done < docker.config
    [[ $count -gt 0 && $failed -eq 0 ]] || return 1
    echo "Verified $count built-in Docker options in $config"
}

extract_matching_config() {
    local image=${1:?Expected a kernel Image}
    local output=${2:?Expected an output config}
    local variant=${3:?Expected AOSP or MIUI}
    local expected_commit candidates_dir candidate localversion
    local -a candidates matches=()

    expected_commit=$(cut -c1-8 ci-artifacts/source-commit.txt)
    if [[ ! "$expected_commit" =~ ^[0-9a-f]{8}$ ]]; then
        echo "Invalid source commit recorded by the prepare step: $expected_commit" >&2
        return 1
    fi

    candidates_dir="ci-diagnostics/${variant,,}-ikconfig-candidates"
    mkdir -p "$candidates_dir"
    rm -f -- "$candidates_dir"/candidate-*.config

    # A patched Image can contain more than one IKCONFIG gzip member.  The
    # upstream extract-ikconfig script stops at the first marker, which may be
    # a stale config embedded in an older binary blob.  Decode every member so
    # the config of the kernel built by this commit can be selected below.
    python - "$image" "$candidates_dir" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys
import zlib

image = Path(sys.argv[1]).read_bytes()
output_dir = Path(sys.argv[2])
marker = b"IKCFG_ST"
offset = 0
seen = set()
written = 0

while True:
    offset = image.find(marker, offset)
    if offset < 0:
        break
    gzip_offset = offset + len(marker)
    offset += 1
    if image[gzip_offset:gzip_offset + 3] != b"\x1f\x8b\x08":
        continue
    try:
        decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
        config = decoder.decompress(image[gzip_offset:]) + decoder.flush()
    except zlib.error:
        continue
    if (b"Kernel Configuration" not in config or b"CONFIG_" not in config
            or b"\x00" in config):
        continue
    digest = sha256(config).hexdigest()
    if digest in seen:
        continue
    seen.add(digest)
    written += 1
    path = output_dir / f"candidate-{written:02d}-offset-{gzip_offset}.config"
    path.write_bytes(config)
    print(f"Decoded IKCONFIG candidate {written} at byte {gzip_offset}: {digest}")

if written == 0:
    raise SystemExit("No valid IKCONFIG gzip members found in packaged Image")
PY

    candidates=("$candidates_dir"/candidate-*.config)
    for candidate in "${candidates[@]}"; do
        localversion=$(grep -m1 '^CONFIG_LOCALVERSION=' "$candidate" || true)
        [[ "$localversion" == *"$expected_commit"* ]] || continue
        verify_config "$candidate" >/dev/null 2>&1 || continue
        if [[ "$variant" == MIUI ]]; then
            grep -qx 'CONFIG_XIAOMI_MIUI=y' "$candidate" || continue
        elif grep -qx 'CONFIG_XIAOMI_MIUI=y' "$candidate"; then
            continue
        fi
        matches+=("$candidate")
    done

    if [[ ${#matches[@]} -ne 1 ]]; then
        echo "Expected exactly one $variant IKCONFIG for commit $expected_commit with all Docker options; found ${#matches[@]}" >&2
        for candidate in "${candidates[@]}"; do
            echo "--- $candidate" >&2
            grep -m1 '^# Linux/.\+ Kernel Configuration$' "$candidate" >&2 || true
            grep -m1 '^CONFIG_LOCALVERSION=' "$candidate" >&2 || true
            verify_config "$candidate" >&2 || true
        done
        return 1
    fi

    cp "${matches[0]}" "$output"
    echo "Selected $variant IKCONFIG from ${matches[0]}"
}

prepare_config() {
    local toolchain="$HOME/proton-clang/proton-clang-20210522/bin"
    export PATH="$toolchain:$PATH"
    local -a make_args=(
        ARCH=arm64 SUBARCH=arm64 CC=clang
        CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-
        CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-
    )
    test -x "$toolchain/clang"
    mkdir -p ci-config/merge ci-config/reload ci-artifacts ci-diagnostics
    cp arch/arm64/configs/alioth_defconfig ci-diagnostics/upstream-alioth.defconfig
    make "${make_args[@]}" O=ci-config/merge alioth_defconfig
    bash scripts/kconfig/merge_config.sh -m -O ci-config/merge \
        ci-config/merge/.config docker.config
    make "${make_args[@]}" O=ci-config/merge olddefconfig
    cp ci-config/merge/.config ci-diagnostics/merged.config
    verify_config ci-config/merge/.config
    make "${make_args[@]}" O=ci-config/merge savedefconfig
    # build.sh loads this defconfig independently for AOSP and MIUI.
    # Only the runner's working copy is changed; never commit this generated file.
    cp ci-config/merge/defconfig arch/arm64/configs/alioth_defconfig
    make "${make_args[@]}" O=ci-config/reload alioth_defconfig
    cp ci-config/reload/.config ci-diagnostics/reloaded.config
    verify_config ci-config/reload/.config
    cp ci-config/reload/.config ci-artifacts/alioth-docker-resolved.config
    cp ci-config/merge/defconfig ci-artifacts/alioth-docker.defconfig
    git rev-parse HEAD > ci-artifacts/source-commit.txt
    {
        clang --version
        make --version
        printf '\nBuild script and fragment hashes:\n'
        sha256sum build.sh docker.config
    } > ci-artifacts/build-environment.txt
}

collect_artifacts() {
    local variant lower archive image_file config
    local -a archives
    mkdir -p ci-artifacts ci-diagnostics ci-config
    shopt -s nullglob
    for variant in AOSP MIUI; do
        lower=${variant,,}
        archives=(Kernel_"${variant}"_alioth_*.zip)
        if [[ ${#archives[@]} -ne 1 ]]; then
            echo "Expected exactly one $variant alioth ZIP, found ${#archives[@]}" >&2
            return 1
        fi
        archive=${archives[0]}
        unzip -tq "$archive"
        image_file="ci-config/${lower}.Image"
        config="ci-diagnostics/alioth-${lower}-final.config"
        # AOSP's out/.config has already been deleted by build.sh at this point.
        # IKCONFIG in kernels/Image is the config of the actual packaged kernel,
        # including upstream KSU/MIUI edits and the compiler's Kconfig resolution.
        unzip -p "$archive" kernels/Image > "$image_file"
        test -s "$image_file"
        extract_matching_config "$image_file" "$config" "$variant"
        rm -f -- "$image_file"
        verify_config "$config"
        if [[ "$variant" == MIUI ]]; then
            grep -qx 'CONFIG_XIAOMI_MIUI=y' "$config"
            cmp out/.config "$config"
        elif grep -qx 'CONFIG_XIAOMI_MIUI=y' "$config"; then
            echo 'AOSP archive unexpectedly contains a MIUI kernel' >&2
            return 1
        fi
        cp "$config" "$archive" ci-artifacts/
    done
    cp docker.config ci-artifacts/
    if [[ -d anykernel/.git ]]; then
        git -C anykernel rev-parse HEAD > ci-artifacts/anykernel-commit.txt
    fi
    if [[ -d KernelSU ]]; then
        git -C KernelSU rev-parse HEAD > ci-artifacts/kernelsu-commit.txt
    fi
    ccache -s > ci-artifacts/ccache-stats.txt
    (cd ci-artifacts && sha256sum -- *.zip *.config *.defconfig *.txt > SHA256SUMS)
}

case "${1:-}" in
    prepare) prepare_config ;;
    verify) verify_config "${2:?Usage: bash docker-ci.sh verify CONFIG}" ;;
    collect) collect_artifacts ;;
    *) echo 'Usage: bash docker-ci.sh {prepare|verify CONFIG|collect}' >&2; exit 2 ;;
esac
