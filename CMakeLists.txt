cmake_minimum_required(VERSION 3.24)
project(xloader NONE)

include(FetchContent)
cmake_policy(SET CMP0169 OLD)

set(XLOADER_CROSS_PREFIX "aarch64-linux-gnu-" CACHE STRING "AArch64 cross toolchain prefix")

# dtc/libfdt (mandatory for xloader build)
set(XLOADER_DTC_URL "https://www.kernel.org/pub/software/utils/dtc/dtc-1.7.1.tar.xz" CACHE STRING "Pinned dtc/libfdt release tarball URL")
set(XLOADER_DTC_SHA256 "398098bac205022b39d3dce5982b98c57f1023f3721a53ebcbb782be4cf7885e" CACHE STRING "Pinned dtc/libfdt release tarball SHA-256")

FetchContent_Declare(dtc
  URL ${XLOADER_DTC_URL} URL_HASH SHA256=${XLOADER_DTC_SHA256})
FetchContent_GetProperties(dtc)
if(NOT dtc_POPULATED)
  FetchContent_Populate(dtc)
  # Patch libfdt_env.h for -nostdlib builds (one-time)
  file(READ "${dtc_SOURCE_DIR}/libfdt/libfdt_env.h" _env)
  string(REPLACE "#include <stdlib.h>" "/* freestanding */" _env "${_env}")
  file(WRITE "${dtc_SOURCE_DIR}/libfdt/libfdt_env.h" "${_env}")
endif()
set(XLOADER_LIBFDT_SRC_DIR "${dtc_SOURCE_DIR}/libfdt")
file(WRITE ${CMAKE_BINARY_DIR}/compiler.h
     "#include <stddef.h>\nchar *strrchr(const char *s, int c);\nvoid abort(void);\n")

# ------------------------------------------------------------------
# XLOADER — the loader stub binary
# ------------------------------------------------------------------
set(XLOADER_BUILD_DIR ${CMAKE_BINARY_DIR}/xloader)
set(XLOADER_ELF ${CMAKE_BINARY_DIR}/xloader.elf)
set(XLOADER_BIN ${CMAKE_BINARY_DIR}/xloader.bin)

set(XLOADER_CFLAGS
  -ffreestanding -nostdlib -march=armv8-a
  -I${CMAKE_SOURCE_DIR}/src -I${CMAKE_SOURCE_DIR}/include
  -I${XLOADER_LIBFDT_SRC_DIR}
  -Wall -Wextra -Werror
)

set(LIBFDT_CFLAGS
  -ffreestanding -march=armv8-a
  -I${CMAKE_SOURCE_DIR}/src -I${CMAKE_SOURCE_DIR}/include
  -I${XLOADER_LIBFDT_SRC_DIR}
  -include ${CMAKE_BINARY_DIR}/compiler.h
  -Wall -Wextra -Werror
)

set(XLOADER_LIBFDT_SOURCES fdt.c fdt_ro.c fdt_rw.c fdt_sw.c fdt_wip.c
  fdt_strerror.c fdt_empty_tree.c fdt_addresses.c)

set(XLOADER_LIBFDT_OBJECTS)
foreach(libfdt_src ${XLOADER_LIBFDT_SOURCES})
  get_filename_component(basename ${libfdt_src} NAME_WE)
  list(APPEND XLOADER_LIBFDT_OBJECTS ${XLOADER_BUILD_DIR}/libfdt_${basename}.o)
endforeach()

set(XLOADER_OBJECTS
  ${XLOADER_BUILD_DIR}/start.o
  ${XLOADER_BUILD_DIR}/string.o
  ${XLOADER_BUILD_DIR}/main.o
  ${XLOADER_LIBFDT_OBJECTS}
)

add_custom_command(
  OUTPUT ${XLOADER_BUILD_DIR}/start.o
  COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_BUILD_DIR}
  COMMAND ${XLOADER_CROSS_PREFIX}gcc ${XLOADER_CFLAGS} -c ${CMAKE_SOURCE_DIR}/src/start.S -o ${XLOADER_BUILD_DIR}/start.o
  DEPENDS ${CMAKE_SOURCE_DIR}/src/start.S
  VERBATIM
)

foreach(src string main)
  add_custom_command(
    OUTPUT ${XLOADER_BUILD_DIR}/${src}.o
    COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_BUILD_DIR}
    COMMAND ${XLOADER_CROSS_PREFIX}gcc ${XLOADER_CFLAGS} -c ${CMAKE_SOURCE_DIR}/src/${src}.c -o ${XLOADER_BUILD_DIR}/${src}.o
    DEPENDS ${CMAKE_SOURCE_DIR}/src/${src}.c ${CMAKE_SOURCE_DIR}/src/string.h ${CMAKE_SOURCE_DIR}/include/bundle.h ${XLOADER_LIBFDT_SRC_DIR}/libfdt.h
    VERBATIM
  )
endforeach()

foreach(libfdt_src ${XLOADER_LIBFDT_SOURCES})
  get_filename_component(basename ${libfdt_src} NAME_WE)
  add_custom_command(
    OUTPUT ${XLOADER_BUILD_DIR}/libfdt_${basename}.o
    COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_BUILD_DIR}
    COMMAND ${XLOADER_CROSS_PREFIX}gcc ${LIBFDT_CFLAGS} -c ${XLOADER_LIBFDT_SRC_DIR}/${libfdt_src} -o ${XLOADER_BUILD_DIR}/libfdt_${basename}.o
    DEPENDS ${XLOADER_LIBFDT_SRC_DIR}/${libfdt_src}
    VERBATIM
  )
endforeach()

add_custom_command(
  OUTPUT ${XLOADER_ELF}
  COMMAND ${XLOADER_CROSS_PREFIX}ld -T ${CMAKE_SOURCE_DIR}/xloader.lds
          -o ${XLOADER_ELF} -Map ${XLOADER_BUILD_DIR}/xloader.map
          ${XLOADER_OBJECTS}
  DEPENDS ${XLOADER_OBJECTS}
  COMMENT "Linking xloader.elf"
  VERBATIM
)

add_custom_command(
  OUTPUT ${XLOADER_BIN}
  COMMAND ${XLOADER_CROSS_PREFIX}objcopy -O binary ${XLOADER_ELF} ${XLOADER_BIN}
  DEPENDS ${XLOADER_ELF}
  COMMENT "Generating xloader.bin"
  VERBATIM
)

add_custom_target(xloader DEPENDS ${XLOADER_BIN})

# ------------------------------------------------------------------
# RELEASE — package for distribution
# ------------------------------------------------------------------
set(XLOADER_RELEASE_DIR ${CMAKE_BINARY_DIR}/release)
set(XLOADER_RELEASE_ARCHIVE ${CMAKE_BINARY_DIR}/xloader-bundle.tar.gz)

add_custom_target(release
  COMMAND ${CMAKE_COMMAND} -E make_directory ${XLOADER_RELEASE_DIR}
  COMMAND ${CMAKE_COMMAND} -E copy ${XLOADER_ELF} ${XLOADER_RELEASE_DIR}/
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/bundle.py ${XLOADER_RELEASE_DIR}/
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/README.md ${XLOADER_RELEASE_DIR}/
  COMMAND ${CMAKE_COMMAND} -E tar "cfz" ${XLOADER_RELEASE_ARCHIVE} -C ${XLOADER_RELEASE_DIR} .
  COMMAND ${CMAKE_COMMAND} -E echo "release → ${XLOADER_RELEASE_ARCHIVE}"
  DEPENDS xloader
  VERBATIM
)
