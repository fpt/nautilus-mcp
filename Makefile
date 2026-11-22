.PHONY: help build install uninstall run list-tools clean test gen-uniffi install-deps fmt fmt-fix

# Install location (override with: make install PREFIX=/usr/local)
PREFIX ?= $(HOME)
BINDIR := $(PREFIX)/bin

# `nautilus-mcp` is always the Rust hub (crates/server): the proxy for other MCP
# servers, wrapper tools, and — on Linux — the portable core tools in-process.
# On macOS the Swift server is installed beside it as `nautilus-mcp-macos`, and
# the hub runs it as its core: unprefixed tools, restarted when rebuilt.
UNAME := $(shell uname -s)
HUB_BIN := crates/target/release/nautilus-mcp
SWIFT_BIN := swift/.build/release/nautilus-mcp

help:
	@echo "nautilus-mcp — a headless MCP server for macOS perception and Android control."
	@echo "The installed nautilus-mcp is also a proxy for other MCP servers (see 'nautilus-mcp help')."
	@echo ""
	@echo "It speaks MCP over stdio. Point an MCP client at the installed binary;"
	@echo "there is no REPL and nothing to run interactively."
	@echo ""
	@echo "Available targets:"
	@echo "  make build        - Build the Rust core (cdylib) and the Swift server"
	@echo "  make install      - Build (release) and install 'nautilus-mcp' to \$$PREFIX/bin (default ~/bin)"
	@echo "  make uninstall    - Remove the installed 'nautilus-mcp'"
	@echo "  make list-tools   - Build and print the tools this machine can offer"
	@echo "  make test         - Run the Rust and Swift test suites"
	@echo "  make gen-uniffi   - Regenerate the UniFFI Swift bindings (after a .udl change)"
	@echo "  make fmt / fmt-fix- Check / apply formatting"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make install-deps - Fetch dependencies"
	@echo ""
	@echo "Android tools need 'adb' on PATH and a device with USB debugging enabled."

install-deps:
	@cd crates && cargo fetch
ifeq ($(UNAME),Darwin)
	@cd swift && swift package resolve
endif

build:
	@echo "Building Rust core and the portable server..."
	@cd crates && cargo build --release
ifeq ($(UNAME),Darwin)
	@echo "Building Swift server..."
	@cd swift && swift build -c release
endif
	@echo "Build complete!"

# The binary links libnautilus_core.dylib by ABSOLUTE path into this repo's
# crates/target/release, so the repo has to stay put for the installed copy to run.
#
# Copy then RE-SIGN. Overwriting a binary that has already been executed leaves
# the kernel holding a stale ad-hoc signature for that path, and every later
# launch dies with SIGKILL "Taskgated Invalid Signature" — no stdout, no stderr,
# nothing on the terminal. An MCP client sees only a server that never answers.
# The copy is byte-identical to a working binary and `codesign -v` calls it
# valid, so nothing about the file itself gives the game away.
install: build
	@mkdir -p "$(BINDIR)"
	@cp $(HUB_BIN) "$(BINDIR)/nautilus-mcp"
	@codesign --force --sign - "$(BINDIR)/nautilus-mcp" 2>/dev/null || true
ifeq ($(UNAME),Darwin)
	@cp $(SWIFT_BIN) "$(BINDIR)/nautilus-mcp-macos"
	@codesign --force --sign - "$(BINDIR)/nautilus-mcp-macos" 2>/dev/null || true
	@echo "✅ Installed $(BINDIR)/nautilus-mcp (hub) and $(BINDIR)/nautilus-mcp-macos (its core)"
	@echo "   The core links the dylib from $(CURDIR)/crates/target/release — keep this repo in place."
	@echo "   Reinstalling while a client is connected is fine: the hub restarts the core."
else
	@echo "✅ Installed $(BINDIR)/nautilus-mcp (pure Rust, movable)"
endif
	@echo "   Register it with an MCP client, e.g.:"
	@echo "       claude mcp add nautilus -- $(BINDIR)/nautilus-mcp"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "   ⚠️  $(BINDIR) is not on your PATH." ;; esac

uninstall:
	@rm -f "$(BINDIR)/nautilus-mcp" "$(BINDIR)/nautilus-mcp-macos"
	@echo "Removed $(BINDIR)/nautilus-mcp"

list-tools: build
ifeq ($(UNAME),Darwin)
	@$(HUB_BIN) --core $(SWIFT_BIN) --list-tools
else
	@$(HUB_BIN) --list-tools
endif

test:
	@echo "Rust tests..."
	@cd crates && cargo test
ifeq ($(UNAME),Darwin)
	@echo "Swift tests..."
	@cd swift && swift test
endif

gen-uniffi:
	@bash scripts/gen_uniffi.sh

fmt:
	@cd crates && cargo fmt --check
ifeq ($(UNAME),Darwin)
	@cd swift && swift format lint --recursive --strict Sources Tests || true
endif

fmt-fix:
	@cd crates && cargo fmt
ifeq ($(UNAME),Darwin)
	@cd swift && swift format --in-place --recursive Sources Tests || true
endif

clean:
	@cd crates && cargo clean
	@rm -rf swift/.build
	@echo "Cleaned."
