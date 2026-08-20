#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: normalize-elf.sh --kind loader|xen --arch aarch64|x86_64 \
       --input INPUT.elf --output OUTPUT.bin --metadata OUTPUT.meta.toml \
       [--descriptor-symbol SYMBOL]

This script is intentionally outside xbundle. It uses binutils to normalize an
ELF executable into a flat raw image plus a small TOML sidecar. xbundle itself
never parses ELF input files.
USAGE
    exit 2
}

kind=
arch=
input=
output=
metadata=
descriptor_symbol=

while (($#)); do
    case "$1" in
        --kind) kind=$2; shift 2 ;;
        --arch) arch=$2; shift 2 ;;
        --input) input=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --metadata) metadata=$2; shift 2 ;;
        --descriptor-symbol) descriptor_symbol=$2; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$kind" && -n "$arch" && -n "$input" && -n "$output" && -n "$metadata" ]] || usage
[[ "$kind" == loader || "$kind" == xen ]] || { echo "invalid kind: $kind" >&2; exit 1; }
[[ -f "$input" ]] || { echo "missing input: $input" >&2; exit 1; }

mkdir -p "$(dirname "$output")" "$(dirname "$metadata")"

# readelf is used only in this normalization stage. Program headers determine
# the memory envelope; objcopy emits the raw bytes and zero-fills internal gaps.
mapfile -t load_lines < <(readelf -lW "$input" 2>/dev/null | awk '$1 == "LOAD" {print $0}')
if ((${#load_lines[@]} == 0)); then
    if [[ "$kind" == xen && "$arch" == aarch64 ]] && file "$input" | grep -q 'ARM64 boot executable'; then
        install -m 0644 "$input" "$output"
        file_size=$(stat -c %s "$output")
        cat >"$metadata" <<EOF_META
format = 1
kind = "$kind"
arch = "$arch"
entry_offset = "0x0"
memory_size = "$(printf '0x%x' "$file_size")"
load_alignment = "0x200000"
source = "$input"
EOF_META
        printf 'normalized %-6s %-8s %s\n' "$kind" "$arch" "$input"
        printf '  raw:             %s (%s bytes)\n' "$output" "$file_size"
        printf '  source base:     0x0\n'
        printf '  entry offset:    0x0\n'
        printf '  memory size:     0x%x\n' "$file_size"
        exit 0
    fi
    echo "$input: no PT_LOAD segments" >&2
    exit 1
fi

source_base=
source_end=0
source_file_end=0
load_alignment=1
for line in "${load_lines[@]}"; do
    # readelf -lW columns:
    # LOAD Offset VirtAddr PhysAddr FileSiz MemSiz Flg Align
    read -r _ off vaddr paddr filesz memsz f1 f2 maybe_align <<<"$line"
    if [[ "$f2" =~ ^0x ]]; then
        seg_alignment=$f2
    else
        seg_alignment=$maybe_align
    fi
    base=$((paddr))
    fsize=$((filesz))
    msize=$((memsz))
    file_end=$((base + fsize))
    end=$((base + msize))
    if [[ -z "$source_base" || $base -lt $source_base ]]; then source_base=$base; fi
    if ((file_end > source_file_end)); then source_file_end=$file_end; fi
    if ((end > source_end)); then source_end=$end; fi
    sa=$((seg_alignment))
    if ((sa > load_alignment)); then load_alignment=$sa; fi
done

entry_hex=$(readelf -hW "$input" | awk '/Entry point address:/ {print $4; exit}')
[[ -n "$entry_hex" ]] || { echo "$input: cannot determine ELF entry" >&2; exit 1; }
entry=$((entry_hex))
entry_phys=
for line in "${load_lines[@]}"; do
    read -r _ off vaddr paddr filesz memsz f1 f2 maybe_align <<<"$line"
    va=$((vaddr))
    pa=$((paddr))
    ms=$((memsz))
    if ((entry >= va && entry < va + ms)); then
        entry_phys=$((pa + (entry - va)))
        break
    fi
done
[[ -n "$entry_phys" ]] || {
    echo "$input: ELF entry $entry_hex is not contained in a PT_LOAD segment" >&2
    exit 1
}
entry_offset=$((entry_phys - source_base))
file_span=$((source_file_end - source_base))
memory_size=$((source_end - source_base))

# Convert the allocatable image to bytes. --gap-fill ensures holes between
# emitted sections have deterministic contents. Trailing BSS is represented by
# memory_size in metadata and becomes p_memsz > p_filesz in the final bundle.
objcopy -O binary --gap-fill 0 "$input" "$output"
# objcopy may trim zero bytes at the end of the final allocatable section.
# Restore the complete PT_LOAD file-backed span so reserved zero-filled data
# such as xloader's descriptor remains patchable in the raw file.
truncate -s "$file_span" "$output"
file_size=$(stat -c %s "$output")
((file_size <= memory_size)) || {
    echo "$input: normalized file larger than PT_LOAD memory envelope" >&2
    exit 1
}

descriptor_line=
if [[ -n "$descriptor_symbol" ]]; then
    sym_hex=$(nm -n "$input" | awk -v wanted="$descriptor_symbol" '$3 == wanted {print "0x"$1; exit}')
    [[ -n "$sym_hex" ]] || { echo "$input: symbol '$descriptor_symbol' not found" >&2; exit 1; }
    sym=$((sym_hex))
    ((sym >= source_base && sym < source_end)) || {
        echo "$input: descriptor symbol outside normalized image" >&2
        exit 1
    }
    descriptor_offset=$((sym - source_base))
    descriptor_line="descriptor_offset = \"$(printf '0x%x' "$descriptor_offset")\""
fi

cat >"$metadata" <<EOF_META
format = 1
kind = "$kind"
arch = "$arch"
entry_offset = "$(printf '0x%x' "$entry_offset")"
memory_size = "$(printf '0x%x' "$memory_size")"
load_alignment = "$(printf '0x%x' "$load_alignment")"
${descriptor_line}
source = "$input"
EOF_META

printf 'normalized %-6s %-8s %s\n' "$kind" "$arch" "$input"
printf '  raw:             %s (%s bytes)\n' "$output" "$file_size"
printf '  source base:     0x%x\n' "$source_base"
printf '  entry offset:    0x%x\n' "$entry_offset"
printf '  memory size:     0x%x\n' "$memory_size"
[[ -z "$descriptor_line" ]] || printf '  descriptor off:  0x%x\n' "$descriptor_offset"
