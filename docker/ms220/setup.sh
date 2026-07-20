#!/usr/bin/env bash
#
# Interactive setup helper for the MS220/MS320/MS22/MS42 build (docker/ms220).
# Bundles the scattered manual steps from README.md / nor/bin/README.md into
# one menu: buildroot, this repo checkout, RedBoot, the kernel source, the
# kernel-headers HTTP server buildroot needs during the container build, and
# the docker image/build itself.
#
# Run this from docker/ms220/ (where it lives).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
BUILDROOT_VERSION=2023.02.4
BUILDROOT_URL="https://www.buildroot.org/downloads/buildroot-${BUILDROOT_VERSION}.tar.xz"
REDBOOT_URL="https://github.com/halmartin/MS42-GPL-sources-3-18-122/raw/master/redboot/redboot-nocrc-sz.bin"
KERNEL_REPO_URL="https://github.com/halmartin/switch-11-22-ms220"
KERNEL_HEADERS_PORT=8000

status() {
    echo "== Status =="

    if [ -d "$SRC_DIR/buildroot/package" ]; then
        echo "[x] buildroot ${BUILDROOT_VERSION} extracted   ($SRC_DIR/buildroot)"
    else
        echo "[ ] buildroot ${BUILDROOT_VERSION} extracted"
    fi

    if [ -L "$SRC_DIR/meraki-builder" ] && [ "$(readlink -f "$SRC_DIR/meraki-builder")" = "$REPO_ROOT" ]; then
        echo "[x] meraki-builder source linked to this checkout (with luton26ctl etc.)"
    else
        echo "[ ] meraki-builder source linked to this checkout"
    fi

    if [ -f "$REPO_ROOT/nor/bin/loader1" ]; then
        echo "[x] RedBoot bootloader   (nor/bin/loader1)"
    else
        echo "[ ] RedBoot bootloader   (nor/bin/loader1)"
    fi

    if [ -d "$SRC_DIR/switch-11-22-ms220" ]; then
        echo "[x] kernel source cloned   ($SRC_DIR/switch-11-22-ms220)"
        if [ -f "$SRC_DIR/switch-11-22-ms220-headers.tar.bz2" ]; then
            echo "[x] kernel headers tarball built"
        else
            echo "[ ] kernel headers tarball built"
        fi
    else
        echo "[ ] kernel source cloned"
    fi

    if docker image inspect ubuntu1804-buildroot >/dev/null 2>&1; then
        echo "[x] docker image built   (ubuntu1804-buildroot)"
    else
        echo "[ ] docker image built"
    fi

    if [ -f "$REPO_ROOT/nor/bin/squashfs" ]; then
        echo "[x] rootfs.squashfs copied to nor/bin/squashfs"
    else
        echo "[ ] rootfs.squashfs copied to nor/bin/squashfs"
    fi

    echo
}

fetch_buildroot() {
    if [ -d "$SRC_DIR/buildroot/package" ]; then
        echo "buildroot already extracted at $SRC_DIR/buildroot, skipping."
        return
    fi
    mkdir -p "$SRC_DIR"
    ( cd "$SRC_DIR" && wget -c "$BUILDROOT_URL" )
    mkdir -p "$SRC_DIR/buildroot"
    tar -C "$SRC_DIR/buildroot" --strip-components=1 -Jxf "$SRC_DIR/buildroot-${BUILDROOT_VERSION}.tar.xz"
    echo "buildroot ${BUILDROOT_VERSION} extracted to $SRC_DIR/buildroot"
}

setup_meraki_builder() {
    # Link straight to this checkout instead of cloning halmartin/meraki-builder -
    # that upstream clone would NOT include local changes (e.g. luton26ctl) made
    # on this branch.
    mkdir -p "$SRC_DIR"
    ln -sfn "$REPO_ROOT" "$SRC_DIR/meraki-builder"
    echo "src/meraki-builder -> $REPO_ROOT"

    if [ ! -d "$SRC_DIR/buildroot" ]; then
        echo "Run buildroot download first (option to fetch buildroot)."
        return 1
    fi

    mkdir -p "$SRC_DIR/buildroot/board" "$SRC_DIR/buildroot/package"
    ln -sfn ../../meraki-builder/buildroot/board/meraki "$SRC_DIR/buildroot/board/meraki"
    ln -sfn ../../meraki-builder/buildroot/packages/pd690xx "$SRC_DIR/buildroot/package/pd690xx"
    ln -sfn ../../meraki-builder/buildroot/packages/find_hdr "$SRC_DIR/buildroot/package/findhdr"
    ln -sfn ../../meraki-builder/buildroot/packages/luton26ctl "$SRC_DIR/buildroot/package/luton26ctl"

    for p in "$REPO_ROOT"/buildroot/patches/*.patch; do
        name=$(basename "$p")
        marker="$SRC_DIR/buildroot/.patched-$name"
        if [ -f "$marker" ]; then
            echo "already applied: $name"
            continue
        fi
        ( cd "$SRC_DIR/buildroot" && patch -p0 < "$p" ) && touch "$marker"
    done

    echo "board/package symlinks + patches done."
}

fetch_redboot() {
    if [ -f "$REPO_ROOT/nor/bin/loader1" ]; then
        echo "nor/bin/loader1 already present, skipping."
        return
    fi
    mkdir -p "$REPO_ROOT/nor/bin"
    wget -c -O "$REPO_ROOT/nor/bin/loader1" "$REDBOOT_URL"
    echo "RedBoot bootloader saved to nor/bin/loader1"
}

fetch_kernel_source() {
    if [ -d "$SRC_DIR/switch-11-22-ms220" ]; then
        echo "kernel source already cloned at $SRC_DIR/switch-11-22-ms220, skipping."
    else
        mkdir -p "$SRC_DIR"
        git clone "$KERNEL_REPO_URL" "$SRC_DIR/switch-11-22-ms220"
    fi
    echo
    echo "Kernel source is a SEPARATE build (not part of buildroot's rootfs build)."
    echo "Follow $SRC_DIR/switch-11-22-ms220/README.md to actually build vmlinux/vmlinux.bin."
    echo "This script cannot safely do that part unattended - it's a different build system."
}

build_kernel_headers_tarball() {
    if [ ! -d "$SRC_DIR/switch-11-22-ms220" ]; then
        echo "Clone the kernel source first (option to fetch kernel source)."
        return 1
    fi
    local out="$SRC_DIR/switch-11-22-ms220-headers.tar.bz2"
    local tmp
    tmp=$(mktemp -d)
    ( cd "$SRC_DIR/switch-11-22-ms220/linux-3.18" && \
      make ARCH=mips INSTALL_HDR_PATH="$tmp" headers_install )
    ( cd "$tmp" && tar -cjf "$out" . )
    rm -rf "$tmp"
    echo "Kernel headers tarball built: $out"
}

serve_kernel_headers() {
    local tarball="$SRC_DIR/switch-11-22-ms220-headers.tar.bz2"
    if [ ! -f "$tarball" ]; then
        echo "Build the kernel headers tarball first (previous menu option)."
        return 1
    fi

    local servedir
    servedir=$(mktemp -d)
    cp "$tarball" "$servedir/linux-3.18.123.tar.bz2"

    echo "Serving $tarball as linux-3.18.123.tar.bz2 on :$KERNEL_HEADERS_PORT"
    echo "This must stay running while the docker build (docker-build/docker-run) executes -"
    echo "the container fetches it from the docker0 bridge gateway (usually 172.17.0.1)."
    echo "Press Ctrl+C to stop."
    ( cd "$servedir" && python3 -m http.server "$KERNEL_HEADERS_PORT" )
}

docker_image() {
    ( cd "$SCRIPT_DIR" && make docker-image )
}

docker_run_build() {
    if [ ! -d "$SRC_DIR/buildroot" ]; then
        echo "Nothing to build yet - run the earlier setup steps first."
        return 1
    fi
    docker run -it --rm -v "$SRC_DIR:/src" ubuntu1804-buildroot
}

copy_squashfs() {
    local squashfs="$SRC_DIR/buildroot/output/images/rootfs.squashfs"
    if [ ! -f "$squashfs" ]; then
        echo "$squashfs not found - build hasn't produced it yet."
        return 1
    fi
    mkdir -p "$REPO_ROOT/nor/bin"
    cp "$squashfs" "$REPO_ROOT/nor/bin/squashfs"
    echo "Copied to nor/bin/squashfs. Run nor/make.sh next to produce switch-new.bin."
}

menu() {
    cat <<'EOF'

MS220 build setup
  1) Show status
  2) Download + extract buildroot
  3) Link this checkout as meraki-builder source + apply patches/symlinks
  4) Download RedBoot bootloader (nor/bin/loader1)
  5) Clone kernel source (switch-11-22-ms220)
  6) Build kernel-headers tarball (needs step 5, and its kernel build)
  7) Serve kernel-headers tarball on :8000 (run this, then start the build elsewhere)
  8) Build docker image
  9) Run the buildroot build in docker
 10) Copy rootfs.squashfs to nor/bin/squashfs
  0) Exit
EOF
    printf 'Choice: '
}

while true; do
    menu
    read -r choice
    case "$choice" in
        1) status ;;
        2) fetch_buildroot ;;
        3) setup_meraki_builder ;;
        4) fetch_redboot ;;
        5) fetch_kernel_source ;;
        6) build_kernel_headers_tarball ;;
        7) serve_kernel_headers ;;
        8) docker_image ;;
        9) docker_run_build ;;
        10) copy_squashfs ;;
        0) exit 0 ;;
        *) echo "Unknown choice: $choice" ;;
    esac
done
