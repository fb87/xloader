CROSS ?= aarch64-linux-gnu-
CC := $(CROSS)gcc
LD := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy

BASE_ADDR ?= 0x40000000
XEN_ELF ?= xen.elf
DOM0 ?=
DOMUS ?=
DTB_FILE ?= /tmp/virt.dtb
QEMU_MEM ?= 1G
QEMU_CPU ?= cortex-a57

BUILD := build
SRC := src
INC := include

CFLAGS := -ffreestanding -nostdlib -march=armv8-a \
          -I$(SRC) -I$(INC) -Wall -Wextra -Werror

OBJS := $(BUILD)/start.o $(BUILD)/string.o $(BUILD)/main.o $(BUILD)/dtb.o

.PHONY: all clean distclean dtb

all: $(BUILD)/bundle.elf

$(DTB_FILE):
	qemu-system-aarch64 -M virt,virtualization=on,secure=off,gic-version=3 \
		-cpu $(QEMU_CPU) -m $(QEMU_MEM) -machine dumpdtb=$@

$(BUILD)/bundle.elf: bundle.py $(OBJS) $(XEN_ELF) $(DTB_FILE)
	@mkdir -p $(BUILD)
	python3 bundle.py \
		--base=$(BASE_ADDR) \
		--xen=$(XEN_ELF) \
		$(if $(DOM0),--dom0='$(DOM0)') \
		$(foreach du,$(DOMUS),--domU='$(du)') \
		--dtb=$(DTB_FILE) \
		--ram-size=$(QEMU_MEM) \
		-o $@ $(OBJS)

$(BUILD)/start.o: $(SRC)/start.S
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/string.o: $(SRC)/string.c $(SRC)/string.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/main.o: $(SRC)/main.c $(INC)/bundle.h $(SRC)/dtb.h $(SRC)/string.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/dtb.o: $(SRC)/dtb.c $(SRC)/dtb.h $(SRC)/string.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD)/*.o $(BUILD)/*.map $(BUILD)/*.S $(BUILD)/*.lds \
	       $(BUILD)/*.elf $(BUILD)/bundle $(BUILD)/bundle.o

distclean: clean
	rm -f bundle.elf
	rm -rf $(BUILD)
