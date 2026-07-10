cmake_minimum_required(VERSION 3.24)

project(xloader NONE)

include(FetchContent)

find_package(Python3 REQUIRED COMPONENTS Interpreter)

option(XLOADER_FETCH_EXTERNALS "Fetch and build Xen, Linux, and BusyBox inputs" OFF)

set(XLOADER_CROSS_PREFIX "aarch64-linux-gnu-" CACHE STRING "AArch64 cross toolchain prefix")
set(XLOADER_BASE_ADDR "0x40000000" CACHE STRING "Bundle base load address")
set(XLOADER_QEMU "qemu-system-aarch64" CACHE FILEPATH "QEMU system emulator")
set(XLOADER_QEMU_MEM "1G" CACHE STRING "QEMU RAM size")
set(XLOADER_QEMU_CPU "cortex-a57" CACHE STRING "QEMU CPU model")
set(XLOADER_QEMU_TIMEOUT "120" CACHE STRING "QEMU test timeout in seconds")

set(XLOADER_XEN_URL "https://downloads.xenproject.org/release/xen/4.21.1/xen-4.21.1.tar.gz" CACHE STRING "Pinned Xen release tarball URL")
set(XLOADER_XEN_SHA256 "e2a69289d6d13c0a71d4f3a39a597741c85c0282d9af1ec5dac495bdcb2872bb" CACHE STRING "Pinned Xen release tarball SHA-256")
set(XLOADER_LINUX_URL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.36.tar.xz" CACHE STRING "Pinned Linux release tarball URL")
set(XLOADER_LINUX_SHA256 "b9676828b737e8fb8eaa5198303d35d35e8df019550be153c8a42c99afe0cdd5" CACHE STRING "Pinned Linux release tarball SHA-256")
set(XLOADER_BUSYBOX_URL "https://busybox.net/downloads/busybox-1.36.1.tar.bz2" CACHE STRING "Pinned BusyBox release tarball URL")
set(XLOADER_BUSYBOX_SHA256 "b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314" CACHE STRING "Pinned BusyBox release tarball SHA-256")
set(XLOADER_MUSL_URL "https://musl.libc.org/releases/musl-1.2.5.tar.gz" CACHE STRING "Pinned musl release tarball URL")
set(XLOADER_MUSL_SHA256 "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4" CACHE STRING "Pinned musl release tarball SHA-256")

if(XLOADER_FETCH_EXTERNALS)
  FetchContent_Declare(xen
    URL ${XLOADER_XEN_URL}
    URL_HASH SHA256=${XLOADER_XEN_SHA256}
  )
  FetchContent_Declare(linux
    URL ${XLOADER_LINUX_URL}
    URL_HASH SHA256=${XLOADER_LINUX_SHA256}
  )
  FetchContent_Declare(busybox
    URL ${XLOADER_BUSYBOX_URL}
    URL_HASH SHA256=${XLOADER_BUSYBOX_SHA256}
  )
  FetchContent_Declare(musl
    URL ${XLOADER_MUSL_URL}
    URL_HASH SHA256=${XLOADER_MUSL_SHA256}
  )
  FetchContent_MakeAvailable(xen linux busybox musl)

  set(XLOADER_XEN_IMAGE_DEFAULT "${xen_SOURCE_DIR}/xen/xen")
  set(XLOADER_LINUX_IMAGE_DEFAULT "${linux_SOURCE_DIR}/arch/arm64/boot/Image")
  set(XLOADER_INITRAMFS_DEFAULT "${CMAKE_BINARY_DIR}/rootfs/initramfs.cpio")
  set(XLOADER_MUSL_PREFIX "${CMAKE_BINARY_DIR}/musl")

  add_custom_command(
    OUTPUT ${XLOADER_XEN_IMAGE_DEFAULT}
    COMMAND ${CMAKE_COMMAND} -E env CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
            make -C ${xen_SOURCE_DIR} XEN_TARGET_ARCH=arm64 xen
    DEPENDS ${xen_SOURCE_DIR}/xen/Makefile
    COMMENT "Building pinned Xen for arm64"
    VERBATIM
  )
  add_custom_target(xen-arm64 DEPENDS ${XLOADER_XEN_IMAGE_DEFAULT})

  add_custom_command(
    OUTPUT ${XLOADER_LINUX_IMAGE_DEFAULT}
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/scripts/patch_linux_extract_cert.py ${linux_SOURCE_DIR}/certs/extract-cert.c
    COMMAND ${CMAKE_COMMAND} -E env ARCH=arm64 CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
            make -C ${linux_SOURCE_DIR} defconfig Image
    DEPENDS ${linux_SOURCE_DIR}/Makefile ${CMAKE_SOURCE_DIR}/scripts/patch_linux_extract_cert.py
    COMMENT "Building pinned Linux Image for arm64"
    VERBATIM
  )
  add_custom_target(linux-arm64 DEPENDS ${XLOADER_LINUX_IMAGE_DEFAULT})

  add_custom_command(
    OUTPUT ${XLOADER_MUSL_PREFIX}/bin/musl-gcc
    COMMAND ${CMAKE_COMMAND} -E env
            MUSL_SRC=${musl_SOURCE_DIR}
            LINUX_SRC=${linux_SOURCE_DIR}
            MUSL_PREFIX=${XLOADER_MUSL_PREFIX}
            CROSS_COMPILE=${XLOADER_CROSS_PREFIX}
            ${CMAKE_SOURCE_DIR}/scripts/build_musl.sh
    DEPENDS ${musl_SOURCE_DIR}/Makefile ${linux_SOURCE_DIR}/Makefile ${CMAKE_SOURCE_DIR}/scripts/build_musl.sh
    COMMENT "Building pinned musl libc for arm64"
    VERBATIM
  )
  add_custom_target(musl-arm64 DEPENDS ${XLOADER_MUSL_PREFIX}/bin/musl-gcc)

  add_custom_command(
    OUTPUT ${XLOADER_INITRAMFS_DEFAULT}
    COMMAND ${CMAKE_COMMAND} -E env
            BUSYBOX_SRC=${busybox_SOURCE_DIR}
            OUT_DIR=${CMAKE_BINARY_DIR}/rootfs
            CROSS_COMPILE=${XLOADER_MUSL_PREFIX}/bin/musl-
            ${CMAKE_SOURCE_DIR}/scripts/build_busybox_initramfs.sh
    DEPENDS ${busybox_SOURCE_DIR}/Makefile ${XLOADER_MUSL_PREFIX}/bin/musl-gcc ${CMAKE_SOURCE_DIR}/scripts/build_busybox_initramfs.sh
    COMMENT "Building pinned BusyBox initramfs"
    VERBATIM
  )
  add_custom_target(busybox-initramfs DEPENDS ${XLOADER_INITRAMFS_DEFAULT})
else()
  set(XLOADER_XEN_IMAGE_DEFAULT "${CMAKE_SOURCE_DIR}/xen.elf")
  set(XLOADER_LINUX_IMAGE_DEFAULT "${CMAKE_SOURCE_DIR}/Image")
  set(XLOADER_INITRAMFS_DEFAULT "${CMAKE_SOURCE_DIR}/initramfs.cpio")
endif()

set(XLOADER_XEN_IMAGE "${XLOADER_XEN_IMAGE_DEFAULT}" CACHE FILEPATH "Xen image used in bundle")
set(XLOADER_DOMAIN0_KERNEL "${XLOADER_LINUX_IMAGE_DEFAULT}" CACHE FILEPATH "Domain 0 Linux Image for dom0less test")
set(XLOADER_DOMAIN1_KERNEL "${XLOADER_LINUX_IMAGE_DEFAULT}" CACHE FILEPATH "Domain 1 Linux Image for dom0less test")
set(XLOADER_DOMAIN0_INITRD "${XLOADER_INITRAMFS_DEFAULT}" CACHE FILEPATH "Domain 0 initramfs")
set(XLOADER_DOMAIN1_INITRD "${XLOADER_INITRAMFS_DEFAULT}" CACHE FILEPATH "Domain 1 initramfs")
set(XLOADER_DOMAIN_MEMORY_KB "131072" CACHE STRING "Memory per dom0less Linux domain in KiB")

set(XLOADER_BUILD_DIR ${CMAKE_BINARY_DIR}/xloader)
set(XLOADER_DTB ${CMAKE_BINARY_DIR}/qemu/virt.dtb)
set(XLOADER_BUNDLE ${CMAKE_BINARY_DIR}/bundle.elf)

set(XLOADER_CFLAGS
  -ffreestanding -nostdlib -march=armv8-a
  -I${CMAKE_SOURCE_DIR}/src -I${CMAKE_SOURCE_DIR}/include
  -Wall -Wextra -Werror
)

set(XLOADER_OBJECTS
  ${XLOADER_BUILD_DIR}/start.o
  ${XLOADER_BUILD_DIR}/string.o
  ${XLOADER_BUILD_DIR}/main.o
  ${XLOADER_BUILD_DIR}/dtb.o
)

add_custom_command(
  OUTPUT ${XLOADER_BUILD_DIR}/start.o
  COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_BUILD_DIR}
  COMMAND ${XLOADER_CROSS_PREFIX}gcc ${XLOADER_CFLAGS} -c ${CMAKE_SOURCE_DIR}/src/start.S -o ${XLOADER_BUILD_DIR}/start.o
  DEPENDS ${CMAKE_SOURCE_DIR}/src/start.S
  VERBATIM
)

foreach(src string main dtb)
  add_custom_command(
    OUTPUT ${XLOADER_BUILD_DIR}/${src}.o
    COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_BUILD_DIR}
    COMMAND ${XLOADER_CROSS_PREFIX}gcc ${XLOADER_CFLAGS} -c ${CMAKE_SOURCE_DIR}/src/${src}.c -o ${XLOADER_BUILD_DIR}/${src}.o
    DEPENDS ${CMAKE_SOURCE_DIR}/src/${src}.c ${CMAKE_SOURCE_DIR}/src/string.h ${CMAKE_SOURCE_DIR}/src/dtb.h ${CMAKE_SOURCE_DIR}/include/bundle.h
    VERBATIM
  )
endforeach()

add_custom_command(
  OUTPUT ${XLOADER_DTB}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_BINARY_DIR}/qemu
  COMMAND ${XLOADER_QEMU}
          -M virt,virtualization=on,secure=off,gic-version=3
          -cpu ${XLOADER_QEMU_CPU}
          -m ${XLOADER_QEMU_MEM}
          -machine dumpdtb=${XLOADER_DTB}
  COMMENT "Generating QEMU virt DTB"
  VERBATIM
)

set(XLOADER_DOMU0_CMDLINE "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init xloader.domain=domu0")
set(XLOADER_DOMU1_CMDLINE "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init xloader.domain=domu1")
set(XLOADER_DOMU0_CFG "kernel=${XLOADER_DOMAIN0_KERNEL}\;initrd=${XLOADER_DOMAIN0_INITRD}\;cmdline=${XLOADER_DOMU0_CMDLINE}\;memory=${XLOADER_DOMAIN_MEMORY_KB}")
set(XLOADER_DOMU1_CFG "kernel=${XLOADER_DOMAIN1_KERNEL}\;initrd=${XLOADER_DOMAIN1_INITRD}\;cmdline=${XLOADER_DOMU1_CMDLINE}\;memory=${XLOADER_DOMAIN_MEMORY_KB}")

add_custom_command(
  OUTPUT ${XLOADER_BUNDLE}
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/bundle.py
          --base=${XLOADER_BASE_ADDR}
          --xen=${XLOADER_XEN_IMAGE}
          --domU=${XLOADER_DOMU0_CFG}
          --domU=${XLOADER_DOMU1_CFG}
          --dtb=${XLOADER_DTB}
          --ram-size=${XLOADER_QEMU_MEM}
          --cross-prefix=${XLOADER_CROSS_PREFIX}
          -o ${XLOADER_BUNDLE}
          ${XLOADER_OBJECTS}
  DEPENDS ${XLOADER_OBJECTS} ${XLOADER_DTB} ${XLOADER_XEN_IMAGE}
          ${XLOADER_DOMAIN0_KERNEL} ${XLOADER_DOMAIN1_KERNEL}
          ${XLOADER_DOMAIN0_INITRD} ${XLOADER_DOMAIN1_INITRD}
          ${CMAKE_SOURCE_DIR}/bundle.py
  COMMENT "Bundling Xen and two dom0less Linux domains"
  VERBATIM
)

add_custom_target(bundle DEPENDS ${XLOADER_BUNDLE})

if(XLOADER_FETCH_EXTERNALS)
  add_dependencies(bundle xen-arm64 linux-arm64 busybox-initramfs)
endif()

add_custom_target(run-qemu-dom0less
  COMMAND ${CMAKE_COMMAND} -E env
          QEMU=${XLOADER_QEMU}
          BUNDLE=${XLOADER_BUNDLE}
          LOG_DIR=${CMAKE_BINARY_DIR}/logs
          QEMU_MEM=${XLOADER_QEMU_MEM}
          QEMU_CPU=${XLOADER_QEMU_CPU}
          QEMU_TIMEOUT=${XLOADER_QEMU_TIMEOUT}
          ${CMAKE_SOURCE_DIR}/scripts/run_qemu_dom0less.sh
  DEPENDS bundle
  USES_TERMINAL
  COMMENT "Running QEMU arm64 dom0less smoke test"
  VERBATIM
)

add_custom_target(run-qemu-dom0less-interactive
  COMMAND ${CMAKE_COMMAND} -E env
          QEMU=${XLOADER_QEMU}
          BUNDLE=${XLOADER_BUNDLE}
          LOG_DIR=${CMAKE_BINARY_DIR}/logs
          QEMU_MEM=${XLOADER_QEMU_MEM}
          QEMU_CPU=${XLOADER_QEMU_CPU}
          ${CMAKE_SOURCE_DIR}/scripts/run_qemu_dom0less_interactive.sh
  DEPENDS bundle
  USES_TERMINAL
  COMMENT "Running QEMU arm64 dom0less interactive session"
  VERBATIM
)
