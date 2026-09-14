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

snapshot_config() {
    local image=${1:?Expected a linked kernel Image}
    local build_config=${2:?Expected the build .config}
    local output=${3:?Expected a snapshot path}

    test -s "$image"
    test -s "$build_config"
    mkdir -p "$(dirname -- "$output")"

    # Vendor blobs can contain an older IKCONFIG before the kernel's own
    # member.  Decode every valid member and require exactly one byte-for-byte
    # match with the .config that produced this still-unpatched Image.
    python - "$image" "$build_config" "$output" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys
import zlib

image = Path(sys.argv[1]).read_bytes()
expected = Path(sys.argv[2]).read_bytes()
output = Path(sys.argv[3])
marker = b"IKCFG_ST"
offset = 0
decoded = 0
matches = []

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
    if not decoder.eof or b"Kernel Configuration" not in config or b"CONFIG_" not in config:
        continue
    decoded += 1
    digest = sha256(config).hexdigest()
    print(f"Decoded pre-KPM IKCONFIG at byte {gzip_offset}: {digest}")
    if config == expected:
        matches.append(gzip_offset)

if len(matches) != 1:
    raise SystemExit(
        f"Expected exactly one pre-KPM IKCONFIG matching out/.config; "
        f"decoded {decoded}, matched {len(matches)}"
    )

output.write_bytes(expected)
print(f"Selected IKCONFIG at byte {matches[0]}")
PY

    cmp "$build_config" "$output"
    verify_config "$output"
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
    local variant lower archive image_file config snapshot_dir snapshot_config
    local expected_commit actual_hash expected_hash unpatched_hash
    local -a archives
    mkdir -p ci-artifacts ci-diagnostics ci-config
    snapshot_dir=${CI_FINAL_CONFIG_DIR:-ci-config/final}
    expected_commit=$(cut -c1-8 ci-artifacts/source-commit.txt)
    [[ "$expected_commit" =~ ^[0-9a-f]{8}$ ]]
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
        snapshot_config="$snapshot_dir/alioth-${lower}-final.config"
        test -s "$snapshot_config"

        # The snapshot was extracted from the linked Image and compared byte for
        # byte with out/.config before KernelPatch/KPM rewrote the image.  Verify
        # that the ZIP contains the exact post-patch image recorded by build.sh.
        unzip -p "$archive" kernels/Image > "$image_file"
        test -s "$image_file"
        actual_hash=$(sha256sum "$image_file" | cut -d ' ' -f 1)
        expected_hash=$(<"$snapshot_dir/alioth-${lower}-packaged-image.sha256")
        unpatched_hash=$(<"$snapshot_dir/alioth-${lower}-unpatched-image.sha256")
        if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ || ! "$unpatched_hash" =~ ^[0-9a-f]{64}$ ]]; then
            echo "Invalid recorded $variant Image checksum" >&2
            return 1
        fi
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            echo "$variant ZIP does not contain the Image recorded at packaging time" >&2
            return 1
        fi
        if [[ ${ENABLE_KSU:-false} == true ]]; then
            if [[ "$actual_hash" == "$unpatched_hash" ]]; then
                echo "$variant Image was not changed by the requested KPM patch" >&2
                return 1
            fi
        else
            if [[ "$actual_hash" != "$unpatched_hash" ]]; then
                echo "$variant Image changed even though KPM was disabled" >&2
                return 1
            fi
            bash scripts/extract-ikconfig "$image_file" > "ci-config/${lower}-packaged.config"
            cmp "$snapshot_config" "ci-config/${lower}-packaged.config"
        fi
        echo "Verified packaged $variant Image SHA-256: $actual_hash"
        cp "$snapshot_config" "$config"
        verify_config "$config"
        grep -q "^CONFIG_LOCALVERSION=.*${expected_commit}" "$config"
        if [[ "$variant" == MIUI ]]; then
            grep -qx 'CONFIG_XIAOMI_MIUI=y' "$config"
            cmp out/.config "$config"
        elif grep -qx 'CONFIG_XIAOMI_MIUI=y' "$config"; then
            echo 'AOSP archive unexpectedly contains a MIUI kernel' >&2
            return 1
        fi
        rm -f -- "$image_file"
        cp "$config" "$archive" ci-artifacts/
        cp "$snapshot_dir"/alioth-"$lower"-*-image.sha256 ci-artifacts/
    done
    cp docker.config ci-artifacts/
    if [[ -d anykernel/.git ]]; then
        git -C anykernel rev-parse HEAD > ci-artifacts/anykernel-commit.txt
    fi
    if [[ -d KernelSU ]]; then
        git -C KernelSU rev-parse HEAD > ci-artifacts/kernelsu-commit.txt
    fi
    ccache -s > ci-artifacts/ccache-stats.txt
    (cd ci-artifacts && sha256sum -- *.zip *.config *.defconfig *.sha256 *.txt > SHA256SUMS)
}

case "${1:-}" in
    prepare) prepare_config ;;
    verify) verify_config "${2:?Usage: bash docker-ci.sh verify CONFIG}" ;;
    snapshot) snapshot_config "${2:?}" "${3:?}" "${4:?}" ;;
    collect) collect_artifacts ;;
    *) echo 'Usage: bash docker-ci.sh {prepare|verify CONFIG|snapshot IMAGE CONFIG OUTPUT|collect}' >&2; exit 2 ;;
esac
