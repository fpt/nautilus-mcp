.PHONY: help build install uninstall run list-tools clean test gen-uniffi install-deps fmt fmt-fix

# Install location (override with: make install PREFIX=/usr/local)
PREFIX ?= $(HOME)
BINDIR := $(PREFIX)/bin

help:
	@echo "nautilus-mcp — a headless MCP server for macOS perception and Android control."
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
	@cd swift && swift package resolve

build:
	@echo "Building Rust core (cdylib)..."
	@cd crates && cargo build --release
	@echo "Building Swift server..."
	@cd swift && swift build -c release
	@echo "Build complete!"

# The binary links libnautilus_core.dylib by ABSOLUTE path into this repo's
# crates/target/release, so the repo has to stay put for the installed copy to run.
install: build
	@mkdir -p "$(BINDIR)"
	@cp swift/.build/release/nautilus-mcp "$(BINDIR)/nautilus-mcp"
	@echo "✅ Installed $(BINDIR)/nautilus-mcp"
	@echo "   Links the dylib from $(CURDIR)/crates/target/release — keep this repo in place."
	@echo "   Register it with an MCP client, e.g.:"
	@echo "       claude mcp add nautilus -- $(BINDIR)/nautilus-mcp"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "   ⚠️  $(BINDIR) is not on your PATH." ;; esac

uninstall:
	@rm -f "$(BINDIR)/nautilus-mcp"
	@echo "Removed $(BINDIR)/nautilus-mcp"

list-tools: build
	@swift/.build/release/nautilus-mcp --list-tools

test:
	@echo "Rust tests..."
	@cd crates && cargo test
	@echo "Swift tests..."
	@cd swift && swift test

gen-uniffi:
	@bash scripts/gen_uniffi.sh

fmt:
	@cd crates && cargo fmt --check
	@cd swift && swift format lint --recursive --strict Sources Tests || true

fmt-fix:
	@cd crates && cargo fmt
	@cd swift && swift format --in-place --recursive Sources Tests || true

clean:
	@cd crates && cargo clean
	@rm -rf swift/.build
	@echo "Cleaned."
