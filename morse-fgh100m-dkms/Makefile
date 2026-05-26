# DKMS wrapper Makefile for Morse Micro FG-H100M HaLow WiFi driver
KSRC ?= /lib/modules/$(shell uname -r)/build
KERNEL_SRC ?= $(KSRC)
PWD := $(shell pwd)

# Force-enable config options for out-of-tree build
OVERRIDES = \
	CONFIG_WLAN_VENDOR_MORSE=m \
	CONFIG_MORSE_SPI=y \
	CONFIG_MORSE_USER_ACCESS=y \
	CONFIG_MORSE_VENDOR_COMMAND=y \
	CONFIG_MORSE_MONITOR=y \
	CONFIG_MORSE_DEBUG_MASK=1 \
	KERNEL_SRC=$(KERNEL_SRC)

all:
	$(MAKE) -C $(KSRC) M=$(PWD)/src $(OVERRIDES) modules

install:
	$(MAKE) -C $(KSRC) M=$(PWD)/src $(OVERRIDES) modules_install INSTALL_MOD_PATH=$(DESTDIR)

clean:
	$(MAKE) -C $(KSRC) M=$(PWD)/src clean
