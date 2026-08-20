#!/usr/bin/env bash
set -euo pipefail

# NixOS 26.05's Xen integration is x86_64-only.  For Arm development we use a
# distro-built Xen hypervisor binary, but still make the final input a Nix store
# object.  No Xen source build occurs here.

url=${XEN_AARCH64_DEB_URL:-https://mirrors.qlu.edu.cn/ubuntu/ubuntu/pool/universe/x/xen/xen-hypervisor-4.20-arm64_4.20.2%2B7-g1badcf5035-2build2_arm64.deb}
mkdir -p build

echo "Prefetching prebuilt Xen ARM64 package into the Nix store..."
json=$(nix store prefetch-file --json "$url")
deb=$(printf '%s' "$json" | sed -n 's/.*"storePath":"\([^"]*\)".*/\1/p')
[[ -n "$deb" && -f "$deb" ]] || { echo "failed to resolve prefetched deb store path" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

dpkg-deb -x "$deb" "$tmp/root"

xen_bin=
while IFS= read -r candidate; do
    if file "$candidate" | grep -Eq 'ARM64 boot executable|AArch64'; then
        xen_bin=$candidate
        break
    fi
done < <(find "$tmp/root" -type f \( -name 'xen-*arm64*' -o -name 'xen' -o -name 'xen-*' \) | sort)

[[ -n "$xen_bin" ]] || {
    echo "could not find an AArch64 ELF Xen hypervisor inside $deb" >&2
    find "$tmp/root" -type f | sort >&2
    exit 1
}

store_path=$(nix store add-file "$xen_bin")
printf '%s\n' "$store_path" > build/xen-aarch64.storepath

echo "Xen ARM64 imported into Nix store:"
echo "  $store_path"
file "$store_path"
