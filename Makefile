ZIG ?= zig
BUILD := build
OPT ?= ReleaseSmall

ifndef LIBFDT_SRC
LIBFDT_SRC :=
endif

.PHONY: all host loaders aarch64 x86_64 libfdt-aarch64 test smoke smoke-aarch64 smoke-x86_64 inspect x86-iso clean check-env check-toml

all: host loaders

$(BUILD):
	mkdir -p $@

host: $(BUILD)/xbundle

$(BUILD)/xbundle: src/xbundle.zig src/manifest.zig src/abi/bundle.zig build.zig | $(BUILD) check-toml
	rm -rf $(BUILD)/host-prefix
	ln -sfn "$(ZIG_TOML_SRC)" $(BUILD)/zig-toml-src
	$(ZIG) build --build-file build.zig -Doptimize=$(OPT) --prefix $(BUILD)/host-prefix
	cp $(BUILD)/host-prefix/bin/xbundle $@

check-toml:
	@test -n "$(ZIG_TOML_SRC)" || { echo "ZIG_TOML_SRC is not set; use 'nix develop'" >&2; exit 1; }
	@test -f "$(ZIG_TOML_SRC)/src/root.zig" || { echo "invalid ZIG_TOML_SRC=$(ZIG_TOML_SRC)" >&2; exit 1; }

loaders: aarch64 x86_64

check-env:
	@test -n "$(LIBFDT_SRC)" || { echo "LIBFDT_SRC is not set; use 'nix develop'" >&2; exit 1; }
	@test -f "$(LIBFDT_SRC)/libfdt.h" || { echo "invalid LIBFDT_SRC=$(LIBFDT_SRC)" >&2; exit 1; }

libfdt-aarch64: $(BUILD)/libfdt-aarch64.a

$(BUILD)/libfdt-aarch64.a: | $(BUILD) check-env
	@rm -rf $(BUILD)/libfdt-aarch64
	@mkdir -p $(BUILD)/libfdt-aarch64
	@set -eu; \
	for src in $(LIBFDT_SRC)/fdt.c $(LIBFDT_SRC)/fdt_ro.c $(LIBFDT_SRC)/fdt_rw.c $(LIBFDT_SRC)/fdt_wip.c $(LIBFDT_SRC)/fdt_sw.c $(LIBFDT_SRC)/fdt_empty_tree.c; do \
		name=$$(basename "$$src" .c); \
		$(ZIG) cc -target aarch64-freestanding-none \
			-ffreestanding -fno-builtin -fno-stack-protector -fPIC -fno-sanitize=undefined \
			-Isrc/runtime/include -I$(LIBFDT_SRC) \
			-c "$$src" -o "$(BUILD)/libfdt-aarch64/$$name.o"; \
	done
	$(ZIG) ar rcs $@ $(BUILD)/libfdt-aarch64/*.o

aarch64: $(BUILD)/xloader-aarch64.elf

$(BUILD)/aarch64-main.o: src/xloader.zig src/abi/bundle.zig src/loader/dt.zig src/runtime/minic.zig | $(BUILD)
	$(ZIG) build-obj src/xloader.zig \
		-target aarch64-freestanding-none -O $(OPT) -fPIC \
		-femit-bin=$@

$(BUILD)/xloader-aarch64.elf: $(BUILD)/aarch64-main.o $(BUILD)/libfdt-aarch64.a src/arch/aarch64/start.S src/arch/aarch64/enter.S linker/aarch64.ld | $(BUILD)
	$(ZIG) cc -target aarch64-freestanding-none -nostdlib -pie \
		-Wl,--no-dynamic-linker -Wl,-T,linker/aarch64.ld \
		src/arch/aarch64/start.S src/arch/aarch64/enter.S $(BUILD)/aarch64-main.o \
		-Wl,--whole-archive $(BUILD)/libfdt-aarch64.a -Wl,--no-whole-archive \
		-o $@

x86_64: $(BUILD)/xloader-x86_64-mb1.elf

$(BUILD)/x86_64-main.o: src/xloader.zig src/abi/bundle.zig src/loader/dt.zig src/runtime/minic.zig | $(BUILD)
	$(ZIG) build-obj src/xloader.zig \
		-target x86_64-freestanding-none -O $(OPT) -fPIC \
		-femit-bin=$@

$(BUILD)/xloader-x86_64-mb1.elf: $(BUILD)/x86_64-main.o src/arch/x86_64/multiboot.S linker/x86_64-mb1.ld | $(BUILD)
	$(ZIG) cc -target x86_64-freestanding-none -nostdlib -pie \
		-Wl,--no-dynamic-linker -Wl,-T,linker/x86_64-mb1.ld \
		src/arch/x86_64/multiboot.S $(BUILD)/x86_64-main.o \
		-o $@

test: host
	$(BUILD)/xbundle abi
	$(ZIG) test src/abi/bundle.zig

inspect: loaders
	file $(BUILD)/xloader-aarch64.elf $(BUILD)/xloader-x86_64-mb1.elf
	readelf -h -l $(BUILD)/xloader-aarch64.elf
	readelf -h -l $(BUILD)/xloader-x86_64-mb1.elf

smoke: smoke-aarch64 smoke-x86_64

smoke-aarch64: $(BUILD)/xloader-aarch64.elf
	@rm -f $(BUILD)/aarch64.log
	@timeout 3s qemu-system-aarch64 \
		-machine virt -cpu cortex-a57 -m 256M \
		-kernel $< -nographic -no-reboot \
		>$(BUILD)/aarch64.log 2>&1 || true
	@grep -q "xloader: hello from position-independent aarch64 Zig core" $(BUILD)/aarch64.log
	@grep -q "invalid or unpatched xbundle descriptor" $(BUILD)/aarch64.log
	@echo "PASS: aarch64 position-independent loader entry smoke"

x86-iso: $(BUILD)/xloader-x86_64.iso

$(BUILD)/xloader-x86_64.iso: $(BUILD)/xloader-x86_64-mb1.elf grub/grub.cfg | $(BUILD)
	grub-file --is-x86-multiboot $(BUILD)/xloader-x86_64-mb1.elf
	rm -rf $(BUILD)/iso-root
	mkdir -p $(BUILD)/iso-root/boot/grub
	cp $(BUILD)/xloader-x86_64-mb1.elf $(BUILD)/iso-root/boot/
	cp grub/grub.cfg $(BUILD)/iso-root/boot/grub/grub.cfg
	grub-mkrescue -o $@ $(BUILD)/iso-root >/dev/null 2>&1

smoke-x86_64: $(BUILD)/xloader-x86_64.iso
	@rm -f $(BUILD)/x86_64.log
	@timeout 4s qemu-system-x86_64 \
		-machine q35 -m 256M \
		-cdrom $< -boot d -display none -serial stdio -no-reboot \
		>$(BUILD)/x86_64.log 2>&1 || true
	@grep -q "xloader: x86 Multiboot entry; switching to long mode" $(BUILD)/x86_64.log
	@grep -q "xloader: hello from x86_64 Zig core" $(BUILD)/x86_64.log
	@grep -q "xloader: no bundle descriptor" $(BUILD)/x86_64.log
	@echo "PASS: x86_64 position-independent long-mode smoke"

clean:
	rm -rf $(BUILD) .zig-cache zig-out

.PHONY: nix-inputs-aarch64 nix-inputs-x86_64 show-inputs-aarch64 show-inputs-x86_64

nix-inputs-aarch64:
	./scripts/nix-inputs.sh aarch64 fetch

nix-inputs-x86_64:
	./scripts/nix-inputs.sh x86_64 fetch

show-inputs-aarch64:
	./scripts/nix-inputs.sh aarch64 print

show-inputs-x86_64:
	./scripts/nix-inputs.sh x86_64 print



.PHONY: nix-xen-aarch64 prepare-sample-aarch64 sample-aarch64 check-sample-aarch64 plan-sample-aarch64 smoke-sample-aarch64 inspect-sample-aarch64

nix-xen-aarch64:
	./scripts/fetch-xen-aarch64.sh

prepare-sample-aarch64: all nix-inputs-aarch64
	./scripts/prepare-sample-aarch64.sh

check-sample-aarch64: prepare-sample-aarch64
	$(BUILD)/xbundle check configs/qemu-aarch64.toml

plan-sample-aarch64: prepare-sample-aarch64
	$(BUILD)/xbundle plan configs/qemu-aarch64.toml

sample-aarch64: prepare-sample-aarch64
	$(BUILD)/xbundle build configs/qemu-aarch64.toml

inspect-sample-aarch64: sample-aarch64
	file $(BUILD)/qemu-aarch64.xbundle.elf
	readelf -h -l $(BUILD)/qemu-aarch64.xbundle.elf
	$(BUILD)/xbundle inspect $(BUILD)/qemu-aarch64.xbundle.elf

smoke-sample-aarch64: sample-aarch64
	@rm -f $(BUILD)/sample-aarch64.log
	@timeout 45s qemu-system-aarch64 \
		-machine virt,virtualization=on -cpu cortex-a57 -m 1G \
		-kernel $(BUILD)/qemu-aarch64.xbundle.elf \
		-nographic -no-reboot \
		>$(BUILD)/sample-aarch64.log 2>&1 || true
	@grep -q "xloader: domains 2" $(BUILD)/sample-aarch64.log
	@grep -q "xloader: entering Xen" $(BUILD)/sample-aarch64.log
	@grep -q "(XEN)" $(BUILD)/sample-aarch64.log
	@grep -q "guest0: xloader sample userspace reached" $(BUILD)/sample-aarch64.log
	@grep -q "guest1: xloader sample userspace reached" $(BUILD)/sample-aarch64.log
	@echo "PASS: aarch64 TOML bundle -> Xen -> two named dom0less Linux userspaces"


.PHONY: sample-aarch64-relocated smoke-pic-aarch64

sample-aarch64-relocated: prepare-sample-aarch64
	$(BUILD)/xbundle build configs/qemu-aarch64-relocated.toml

smoke-pic-aarch64: sample-aarch64 sample-aarch64-relocated
	@sha256sum $(BUILD)/xloader-aarch64.elf > $(BUILD)/xloader-pic.sha256
	@rm -f $(BUILD)/sample-aarch64-relocated.log
	@timeout 45s qemu-system-aarch64 \
		-machine virt,virtualization=on -cpu cortex-a57 -m 1G \
		-kernel $(BUILD)/qemu-aarch64-relocated.xbundle.elf \
		-nographic -no-reboot \
		>$(BUILD)/sample-aarch64-relocated.log 2>&1 || true
	@grep -q "xloader: entering Xen" $(BUILD)/sample-aarch64-relocated.log
	@grep -q "guest0: xloader sample userspace reached" $(BUILD)/sample-aarch64-relocated.log
	@grep -q "guest1: xloader sample userspace reached" $(BUILD)/sample-aarch64-relocated.log
	@echo "PASS: identical PIC xloader boots from alternate bundle placement"
