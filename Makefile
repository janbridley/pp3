# pp3: build and install.
SWIFT ?= swiftc
PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin

.PHONY: all clean install lint uninstall

all: pp3

pp3: pp3.swift
	$(SWIFT) -O $< -o $@

install: all
	install -d $(BINDIR)
	install -m 0755 pp3 $(BINDIR)

uninstall:
	rm -f $(BINDIR)/pp3

lint:
	swiftc -O -warnings-as-errors pp3.swift -o /tmp/pp3-lint
	swiftc -swift-version 6 -O -warnings-as-errors pp3.swift -o /tmp/pp3-lint6
	@awk 'length > 100 { print FNR": over 100 cols"; e = 1 } END { exit e }' pp3.swift
	@echo "lint: clean (werror in both modes + column check)"

clean:
	rm -f pp3
