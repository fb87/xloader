#!/usr/bin/env bash
set -euo pipefail

: "${MUSL_SRC:?MUSL_SRC is required}"
: "${MUSL_PREFIX:?MUSL_PREFIX is required}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"

jobs="${PARALLEL_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}}"

mkdir -p "${MUSL_PREFIX}"

if [ -n "${LINUX_SRC:-}" ]; then
  make -C "${LINUX_SRC}" ARCH=arm64 \
    INSTALL_HDR_PATH="${MUSL_PREFIX}" headers_install
fi

cd "${MUSL_SRC}"
if [ ! -f config.mak ]; then
  ./configure \
    --target=aarch64-linux-musl \
    --prefix="${MUSL_PREFIX}" \
    CROSS_COMPILE="${CROSS_COMPILE}"
fi

make -j"${jobs}"
make install || true

mkdir -p "${MUSL_PREFIX}/bin"
sh "${MUSL_SRC}/tools/musl-gcc.specs.sh" \
  "${MUSL_PREFIX}/include" \
  "${MUSL_PREFIX}/lib" \
  "/lib/ld-musl-aarch64.so.1" > "${MUSL_PREFIX}/lib/musl-gcc.specs"

cat > "${MUSL_PREFIX}/bin/musl-gcc" <<EOF
#!/bin/sh
exec ${CROSS_COMPILE}gcc --sysroot=${MUSL_PREFIX} -specs ${MUSL_PREFIX}/lib/musl-gcc.specs -fno-link-libatomic "\$@"
EOF
chmod +x "${MUSL_PREFIX}/bin/musl-gcc"

for tool in ar as ld nm objcopy objdump ranlib readelf strip; do
  ln -sf "$(command -v "${CROSS_COMPILE}${tool}")" "${MUSL_PREFIX}/bin/musl-${tool}"
done
