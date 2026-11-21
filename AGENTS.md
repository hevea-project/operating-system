# Agents Guide: Home Assistant Operating System (HAOS)

This document provides essential knowledge for AI agents working in the Home Assistant Operating System repository.

## Project Overview
HAOS is a Linux-based operating system optimized for Home Assistant. It is built using **Buildroot** and uses **Docker** as its container engine. It targets various single-board computers (SBCs) and x86-64 systems.

## Core Architecture
- **Build System**: [Buildroot](https://buildroot.org/) is used to manage the entire build process, including the toolchain, kernel, bootloader, and root filesystem.
- **External Buildroot Config**: `buildroot-external/` contains HAOS-specific configurations, packages, and board support.
- **Containerization**: Uses Docker to run Home Assistant Core and Apps.
- **Update Mechanism**: Uses [RAUC](https://rauc.io/) for Over-the-Air (OTA) and USB updates.
- **Filesystem**: Uses `SquashFS` (LZ4) for the read-only root filesystem and `ZRAM` (LZ4) for `/tmp`, `/var`, and swap.

## Essential Commands

### Building the OS
The main `Makefile` in the root directory wraps Buildroot commands.

- **Build a specific target**:
  ```bash
  make <target>
  ```
  (Targets are defined by `_defconfig` files in `buildroot-external/configs/`)

- **Configure a target**:
  ```bash
  make <target>-config
  ```

- **List supported targets**:
  ```bash
  make help
  ```

- **Clean the build directory**:
  ```bash
  make distclean
  ```
  *Note: Running a build for a different target without `distclean` first will trigger a warning and potentially cause issues.*

### Testing
Tests are primarily written in Python using `pytest`.

- **Run all tests**:
  ```bash
  ./tests/run_tests.sh
  ```
  *This script sets up a virtual environment and installs requirements if necessary.*

- **Run specific tests**:
  ```bash
  ./tests/run_tests.sh <test_path>
  ```

### Other Utilities
- **Buildroot Help**: `make buildroot-help` (for direct Buildroot commands).

## Code Organization

- `buildroot/`: The upstream Buildroot directory. **Do not modify this directly** unless specifically instructed; changes should typically go through `buildroot-external`.
- `buildroot-external/`:
  - `configs/`: Board-specific defconfigs.
  - `board/`: Board-specific configurations (e.g., Raspberry Pi, Odroid).
  - `package/`: HAOS-specific packages and their build recipes.
  - `configs/base-haos.conf`: Common base configuration included by all board defconfigs.
- `scripts/`: Various helper scripts for kernel, firmware, and DTB updates.
- `tests/`: Test suites (smoke tests, supervisor tests, etc.).
- `Documentation/`: Project documentation.

## Conventions & Patterns

### Buildroot Integration
- New packages should be added to `buildroot-external/package/`.
- Board-specific overrides are managed via `buildroot-external/board/` or by including fragments in the board's defconfig.
- Use `buildroot-external/configs/base-haos.conf` for settings that should apply to all targets.

### Naming Conventions
- **Buildroot Packages**: Follow standard Buildroot naming (`pkg-name.mk`, `pkg-name.hash`, `Config.in`).
- **Defconfigs**: Named `<board>_defconfig` (e.g., `rpi4_64_defconfig`).

## Important Gotchas
- **Output Directory**: The build output is directed to `output/` by default. If switching targets, you **must** run `make distclean` first.
- **Buildroot vs. External**: Most development happens in `buildroot-external/`. Avoid making changes to the `buildroot/` directory directly.
- **Hardware Support**: Adding new hardware requires following the process defined in [ADR-0015](https://github.com/home-assistant/architecture/blob/master/adr/0015-home-assistant-os.md).
- **Kernel Configuration**: Kernel fragments are often used to extend the base kernel configuration for specific hardware or features.

## Testing Strategy
- **Smoke Tests**: Located in `tests/smoke_test/`, these check basic OS functionality.
- **Supervisor Tests**: Located in `tests/supervisor_test/`.
- **QEMU Strategy**: Many tests use a QEMU-based strategy for automated testing in CI environments.

## Versioning
- OS version is defined in `buildroot-external/meta`: `VERSION_MAJOR.VERSION_MINOR[.VERSION_SUFFIX]`.
- `MAJOR.MINOR` tracks the upstream HAOS base (e.g. `18.4` = HAOS 18.4). Hevea does not change it.
- `VERSION_SUFFIX` is the Hevea patch/pre-release level. It must be **semver-valid**:
  - numeric only: `1` → `18.4.1`
  - or pre-release: `1-hevea` → `18.4.1-hevea`
  - NOT a bare word like `hevea1` (`18.4.hevea1` is invalid semver and breaks version comparison in the Supervisor).
- Hevea add-ons and services use their own independent semver (e.g. `1.2.3` in `config.yaml`).
- The version is consumed by `scripts/generate-version-json.sh` (update server) and `buildroot-external/scripts/name.sh` (image names).
