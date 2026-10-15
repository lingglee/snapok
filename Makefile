.PHONY: dev build release test linux linux-package linux-test

# Build and launch Snapok Dev, rebuilding and relaunching on source changes.
dev:
	@./scripts/dev.sh

# Build dist/Snapok Dev.app (release configuration).
build:
	@./scripts/build-app.sh release

# Build dist/Snapok.app on the release channel.
release:
	@CHANNEL=release ./scripts/build-app.sh release

# Run every scripts/test-*.sh check.
test:
	@set -e; for script in scripts/test-*.sh; do echo "==> $$script"; ./$$script; done

# Run the native Ubuntu port from the working tree.
linux:
	@./linux/snapok

# Build an installable Ubuntu/Debian package in dist/.
linux-package:
	@./linux/build-deb.sh

# Run Linux core tests without opening a window.
linux-test:
	@./linux/test.sh
