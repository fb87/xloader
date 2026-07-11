cmake_minimum_required(VERSION 3.24)
project(xloader-test NONE)

include(FetchContent)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

option(XLOADER_FETCH_EXTERNALS "Fetch and build Xen, Linux, and BusyBox inputs" OFF)

cmake_policy(SET CMP0169 OLD)

set(XLOADER_CROSS_PREFIX "aarch64-linux-gnu-" CACHE STRING "AArch64 cross toolchain prefix")
set(XLOADER_QEMU "qemu-system-aarch64" CACHE FILEPATH "QEMU system emulator")
set(XLOADER_QEMU_MEM "1G" CACHE STRING "QEMU RAM size")
set(XLOADER_QEMU_CPU "cortex-a57" CACHE STRING "QEMU CPU model")
set(XLOADER_QEMU_TIMEOUT "120" CACHE STRING "QEMU test timeout in seconds")

set(XLOADER_XEN_URL "https://downloads.xenproject.org/release/xen/4.21.1/xen-4.21.1.tar.gz")
set(XLOADER_XEN_SHA256 "e2a69289d6d13c0a71d4f3a39a597741c85c0282d9af1ec5dac495bdcb2872bb")
set(XLOADER_LINUX_URL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.36.tar.xz")
set(XLOADER_LINUX_SHA256 "b9676828b737e8fb8eaa5198303d35d35e8df019550be153c8a42c99afe0cdd5")
set(XLOADER_BUSYBOX_URL "https://busybox.net/downloads/busybox-1.36.1.tar.bz2")
set(XLOADER_BUSYBOX_SHA256 "b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314")
set(XLOADER_MUSL_URL "https://musl.libc.org/releases/musl-1.2.5.tar.gz")
set(XLOADER_MUSL_SHA256 "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4")

set(XLOADER_DTC_URL "https://www.kernel.org/pub/software/utils/dtc/dtc-1.7.1.tar.xz")
set(XLOADER_DTC_SHA256 "398098bac205022b39d3dce5982b98c57f1023f3721a53ebcbb782be4cf7885e")

FetchContent_Declare(dtc
  URL ${XLOADER_DTC_URL}
  URL_HASH SHA256=${XLOADER_DTC_SHA256}
)
FetchContent_GetProperties(dtc)
if(NOT dtc_POPULATED)
  FetchContent_Populate(dtc)
endif()
set(XLOADER_DTC_BINARY "${dtc_SOURCE_DIR}/dtc")

# Build dtc
add_custom_command(
  OUTPUT ${XLOADER_DTC_BINARY}
  COMMAND ${CMAKE_COMMAND} -E env CROSS_COMPILE= make -C ${dtc_SOURCE_DIR} dtc
  DEPENDS ${dtc_SOURCE_DIR}/Makefile
  COMMENT "Building dtc"
  VERBATIM
)
add_custom_target(dtc-bin DEPENDS ${XLOADER_DTC_BINARY})

if(XLOADER_FETCH_EXTERNALS)
  FetchContent_Declare(xen URL ${XLOADER_XEN_URL} URL_HASH SHA256=${XLOADER_XEN_SHA256})
  FetchContent_Declare(linux URL ${XLOADER_LINUX_URL} URL_HASH SHA256=${XLOADER_LINUX_SHA256})
  FetchContent_Declare(busybox URL ${XLOADER_BUSYBOX_URL} URL_HASH SHA256=${XLOADER_BUSYBOX_SHA256})
  FetchContent_Declare(musl URL ${XLOADER_MUSL_URL} URL_HASH SHA256=${XLOADER_MUSL_SHA256})
  FetchContent_MakeAvailable(xen linux busybox musl)

  set(XEN_IMAGE "${xen_SOURCE_DIR}/xen/xen")
  set(LINUX_IMAGE "${linux_SOURCE_DIR}/arch/arm64/boot/Image")
  set(INITRAMFS "${CMAKE_BINARY_DIR}/rootfs/initramfs.cpio")
  set(MUSL_PREFIX "${CMAKE_BINARY_DIR}/musl")

  add_custom_command(OUTPUT ${XEN_IMAGE}
    COMMAND ${CMAKE_COMMAND} -E env CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
      make -C ${xen_SOURCE_DIR} XEN_TARGET_ARCH=arm64 xen
    DEPENDS ${xen_SOURCE_DIR}/xen/Makefile
    COMMENT "Building Xen")
  add_custom_target(xen-arm64 DEPENDS ${XEN_IMAGE})

  add_custom_command(OUTPUT ${LINUX_IMAGE}
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/patch_linux_extract_cert.py ${linux_SOURCE_DIR}/certs/extract-cert.c
    COMMAND ${CMAKE_COMMAND} -E env ARCH=arm64 CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
      make -C ${linux_SOURCE_DIR} defconfig Image
    DEPENDS ${linux_SOURCE_DIR}/Makefile ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/patch_linux_extract_cert.py
    COMMENT "Building Linux")
  add_custom_target(linux-arm64 DEPENDS ${LINUX_IMAGE})

  add_custom_command(OUTPUT ${MUSL_PREFIX}/bin/musl-gcc
    COMMAND ${CMAKE_COMMAND} -E env
      MUSL_SRC=${musl_SOURCE_DIR} LINUX_SRC=${linux_SOURCE_DIR}
      MUSL_PREFIX=${MUSL_PREFIX} CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
      ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_musl.sh
    DEPENDS ${musl_SOURCE_DIR}/Makefile ${linux_SOURCE_DIR}/Makefile ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_musl.sh
    COMMENT "Building musl")
  add_custom_target(musl-arm64 DEPENDS ${MUSL_PREFIX}/bin/musl-gcc)

  add_custom_command(OUTPUT ${INITRAMFS}
    COMMAND ${CMAKE_COMMAND} -E env
      BUSYBOX_SRC=${busybox_SOURCE_DIR} OUT_DIR=${CMAKE_BINARY_DIR}/rootfs
      CROSS_COMPILE=${MUSL_PREFIX}/bin/musl-
      ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_busybox_initramfs.sh
    DEPENDS ${busybox_SOURCE_DIR}/Makefile ${MUSL_PREFIX}/bin/musl-gcc ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/build_busybox_initramfs.sh
    COMMENT "Building BusyBox initramfs")
  add_custom_target(busybox-initramfs DEPENDS ${INITRAMFS})

  # Generate bundle.toml from template
  set(XLOADER_ELF "${CMAKE_BINARY_DIR}/../xloader.elf")
  set(BUNDLE_TOML "${CMAKE_BINARY_DIR}/bundle.toml")
  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/bundle.toml.in ${BUNDLE_TOML})

  # Run bundle.py to produce bundle.bin
  set(BUNDLE_BIN "${CMAKE_BINARY_DIR}/bundle.bin")
  add_custom_command(OUTPUT ${BUNDLE_BIN}
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/../bundle.py
      --config ${BUNDLE_TOML} --dtc-path ${XLOADER_DTC_BINARY} -o ${BUNDLE_BIN}
    DEPENDS ${XEN_IMAGE} ${LINUX_IMAGE} ${INITRAMFS} ${XLOADER_ELF} ${XLOADER_DTC_BINARY} ${BUNDLE_TOML}
    COMMENT "Generating bundle.bin")
  add_custom_target(bundle DEPENDS ${BUNDLE_BIN})
  add_dependencies(bundle xen-arm64 linux-arm64 busybox-initramfs dtc-bin)

  # QEMU test
  add_custom_target(run-qemu-test
    COMMAND ${CMAKE_COMMAND} -E env
      QEMU=${XLOADER_QEMU} BUNDLE=${BUNDLE_BIN} LOG_DIR=${CMAKE_BINARY_DIR}/logs
      QEMU_MEM=${XLOADER_QEMU_MEM} QEMU_CPU=${XLOADER_QEMU_CPU}
      QEMU_TIMEOUT=${XLOADER_QEMU_TIMEOUT}
      ${CMAKE_CURRENT_SOURCE_DIR}/../scripts/run_qemu_dom0less.sh
    DEPENDS bundle USES_TERMINAL
    COMMENT "Running QEMU dom0less smoke test"
    VERBATIM)
endif()
