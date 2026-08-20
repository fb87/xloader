#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: scripts/nix-inputs.sh <aarch64|x86_64> <fetch|print|env>

AArch64:
  Linux comes from pinned nixpkgs/cache.
  Xen is a prebuilt ARM64 hypervisor imported into the Nix store by
  scripts/fetch-xen-aarch64.sh (no Xen compilation).

x86_64:
  Xen and Linux both come from pinned nixpkgs/cache; local builds disabled.
USAGE
    exit 2
}

[[ $# -eq 2 ]] || usage
arch=$1
cmd=$2

case "$arch" in
    aarch64) system=aarch64-linux ;;
    x86_64)  system=x86_64-linux ;;
    *) usage ;;
esac

meta=".#bundleInputs.${system}"
nix_raw() { nix eval --raw "$meta.$1"; }

linux_path=$(nix_raw linuxPath)
linux_version=$(nix_raw linuxVersion)
linux_target=$(nix_raw linuxTarget)

if [[ $arch == x86_64 ]]; then
    xen_path=$(nix_raw xenPath)
    xen_version=$(nix_raw xenVersion)
else
    xen_version=ubuntu-4.20.2-prebuilt
    xen_path=
    if [[ -f build/xen-aarch64.storepath ]]; then
        xen_path=$(cat build/xen-aarch64.storepath)
    fi
fi

print_info() {
    printf 'target:       %s\n' "$system"
    printf 'Xen:          %s\n' "$xen_version"
    printf 'Xen image:    %s\n' "${xen_path:-<run make nix-xen-aarch64>}"
    printf 'Linux:        %s\n' "$linux_version"
    printf 'Linux target: %s\n' "$linux_target"
    printf 'Linux image:  %s\n' "$linux_path"
}

case "$cmd" in
    fetch)
        echo "Fetching cached Linux input (local builds disabled)..."
        nix build --no-link --max-jobs 0 ".#packages.${system}.linux-input"
        if [[ $arch == x86_64 ]]; then
            echo "Fetching cached Xen x86_64 input (local builds disabled)..."
            nix build --no-link --max-jobs 0 ".#packages.${system}.xen-boot-input"
        else
            if [[ -z "$xen_path" || ! -f "$xen_path" ]]; then
                ./scripts/fetch-xen-aarch64.sh
                xen_path=$(cat build/xen-aarch64.storepath)
            fi
        fi
        [[ -f "$linux_path" ]] || { echo "Linux artifact not present: $linux_path" >&2; exit 1; }
        [[ -f "$xen_path" ]] || { echo "Xen artifact not present: $xen_path" >&2; exit 1; }
        print_info
        ;;
    print) print_info ;;
    env)
        [[ -n "$xen_path" ]] || { echo "AArch64 Xen not imported; run make nix-xen-aarch64" >&2; exit 1; }
        printf 'XEN_IMAGE=%q\n' "$xen_path"
        printf 'LINUX_IMAGE=%q\n' "$linux_path"
        printf 'XEN_VERSION=%q\n' "$xen_version"
        printf 'LINUX_VERSION=%q\n' "$linux_version"
        ;;
    *) usage ;;
esac
