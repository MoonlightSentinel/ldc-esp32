#!/bin/bash

set -eux

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SOURCES="$ROOT/source"
TESTS="$ROOT/test"

RELEASE="${RELEASE:-$ROOT/release}"
LLVM_RELEASE="${LLVM_RELEASE:-$RELEASE/llvm}"
LDC_RELEASE="${LDC_RELEASE:-$RELEASE/ldc2}"
LWDR_RELEASE="${LWDR_RELEASE:-$RELEASE/lwdr}"

BUILD="${BUILD:-$ROOT/build}"
LLVM_BUILD_DIR="$BUILD/llvm"
LDC_BUILD_DIR="$BUILD/ldc2"
LWDR_BUILD_DIR="$BUILD/lwdr"

DEFAULT_TRIPLE="xtensa-esp32-none-elf"

# Apply patches to all source directories
function patchSources() {
	for folder in $SOURCES/patches/*/.git
	do
		applyPatches "$(basename $(dirname $folder))"
	done
}

# Apply pathches to a single source directory
function applyPatches() {
	local repo="$1"
	local folder="$SOURCES/$repo"
	local marker="$folder/.patched"

	if [ ! -f $marker ]
	then
		git -C "$folder" apply --ignore-whitespace $SOURCES/patches/$repo/*
		touch $marker
	fi
}

function buildLLVM() {

	#applyPatches espressif-llvm

	mkdir -p "$LLVM_BUILD_DIR"
	mkdir -p "$LLVM_RELEASE"
    cd "$LLVM_BUILD_DIR"

	cmake "$SOURCES/espressif-llvm/llvm" \
		-G "Ninja" \
		-D LLVM_ENABLE_PROJECTS="clang;libcxx;libcxxabi" \
		-D LLVM_BUILD_LLVM_DYLIB= \
		-D LLVM_EXPERIMENTAL_TARGETS_TO_BUILD="Xtensa" \
		-D LLVM_TARGETS_TO_BUILD="Xtensa" \
		-D TARGET_TRIPLE="$DEFAULT_TRIPLE" \
		-D LLVM_DEFAULT_TARGET_TRIPLE="$DEFAULT_TRIPLE" \
		-D LLVM_ENABLE_WARNINGS=OFF \
		-D CMAKE_BUILD_TYPE=Release \
		-D CMAKE_INSTALL_PREFIX="$LLVM_RELEASE"

	ninja
	ninja install

	# Check that the generated LLVM/Clang works
	local ASM="$BUILD/test.S"
	"$LLVM_RELEASE/bin/clang" -target xtensa -S "$TESTS/example.c" -o "$ASM"
	cat "$ASM"
	rm "$ASM"
}

function buildLDC() {

	applyPatches ldc

	mkdir -p "$LDC_BUILD_DIR"
	cd "$LDC_BUILD_DIR"

	cmake "$SOURCES/ldc" \
		-G Ninja \
		-D BUILD_SHARED_LIBS=OFF \
		-D CMAKE_BUILD_TYPE=Release \
		-D CMAKE_INSTALL_PREFIX="$LDC_RELEASE" \
		-D LDC_DYNAMIC_COMPILE=OFF \
		-D LDC_ENABLE_PLUGINS=OFF \
		-D LDC_INSTALL_LLVM_RUNTIME_LIBS=OFF \
		-D LDC_LINK_MANUALLY=ON \
		-D LLVM_ROOT_DIR="$LLVM_RELEASE" \
		${LDC_CMAKE_EXTRA_FLAGS:-}


	# Patch the generated build.ninja
	# Ensure that -lLLVMGlobalISel appears before -lLLVMCodeGen
	sed -i 's/ -lLLVMCodeGen/ -lLLVMGlobalISel -lLLVMCodeGen/' build.ninja
	sed -i 's/ -Xcc=-lLLVMCodeGen/ -Xcc=-lLLVMGlobalISel -Xcc=-lLLVMCodeGen/' build.ninja

	ninja ldc2 ldmd2

	mkdir -p "$LDC_RELEASE/bin"

	# Cannot use install because that attempts to build druntime + phobos (which fail when targeting xtensa)
	# ninja install
	cp -r "$LDC_BUILD_DIR/bin/ldc2" "$LDC_RELEASE/bin/"
	cp -r "$LDC_BUILD_DIR/bin/ldmd2" "$LDC_RELEASE/bin/"

	# Patch the configuration:
	local REL_ROOT='%%ldcbinarypath%%/..'
	sed \
		-e "s|$LDC_BUILD_DIR|$REL_ROOT|" \
		-e "s|$LDC_RELEASE|$REL_ROOT|" \
		-e "s|$SOURCES/ldc|$REL_ROOT|" \
		-e 's|"-defaultlib=phobos2-ldc,druntime-ldc"|"-defaultlib=lwdr", "-mcpu=esp32", "--gcc=xtensa-esp32-elf-gcc"|' \
		-e 's|include/d"|include/lwdr","-I%%ldcbinarypath%%/../include/default"|' \
		"$LDC_BUILD_DIR/bin/ldc2_install.conf" \
		> "$LDC_RELEASE/bin/ldc2.conf"

	# Workaround: Manually copy the source files
	mkdir -p "$LDC_RELEASE/include/"
	cp -r "$SOURCES/ldc/runtime/druntime/src" "$LDC_RELEASE/include/default"
	cp -r "$SOURCES/ldc/runtime/phobos/std" "$LDC_RELEASE/include/default/"

	# Check that the generated LDC works
	"$LDC_RELEASE/bin/ldc2" -c -v $TESTS/example.d
}

# Build LWDR libraries
function buildLWDR() {

	applyPatches lwdr

	mkdir -p "$LWDR_BUILD_DIR"
	mkdir -p "$LWDR_RELEASE/include"
	mkdir -p "$LWDR_RELEASE/lib"

	cp -r "$SOURCES/lwdr/source" "$LWDR_RELEASE/include/lwdr"

	ln -s "$LDC_RELEASE/include/default" "$LWDR_RELEASE/include/default"

	cd "$LWDR_RELEASE/include/"
	local files="$(find lwdr -name '*.d')"

	local arrays="-version=LWDR_DynamicArray"
	local closures="-version=LWDR_ManualDelegate"
	local modctors="-version=LWDR_ModuleCtors"
	local tls="-version=LWDR_TLS"
	local synchronized="-version=LWDR_Sync"

	local name="liblwdr"
	local flags=""

	# TODO: TLS
	for trait in "" arrays closures modctors synchronized
	do
		if [ "$trait" != "" ]; then
			name="$name-$trait"
			flags="$flags ${!trait}"
		fi

		$LDC_RELEASE/bin/ldmd2 \
			--lib \
			--oq \
			-od="$LWDR_BUILD_DIR" \
			-of="$LWDR_RELEASE/lib/$name.a" \
			$flags \
			$files
	done

	rm "$LWDR_RELEASE/include/default"
}

function buildArchive() {

	# Include LWDR files via symlink (expanded by tar)
	local LINKS=(
		"include/lwdr"
		"lib"
	)

	for LINK in ${LINKS[@]}; do
		ln -s "$LWDR_RELEASE/$LINK" "$LDC_RELEASE/$LINK"
	done

	cd $RELEASE

	tar cfhz "ldc2-xtensa-${OS_NAME:-$(uname)}.tar.xz" llvm ldc2

	# Remove the symlinks s.t. they aren't included in the cache
	for LINK in ${LINKS[@]}; do
		rm "$LDC_RELEASE/$LINK"
	done

	ls -aul "$RELEASE"
}

function clean() {
	rm -r \
		"$LLVM_BUILD_DIR" \
		"$LDC_BUILD_DIR" \
		"$LLVM_RELEASE" \
		"$LDC_RELEASE" \
		"$LWDR_RELEASE" \
		|| true
}

for TARGET in "$@"
do
	case "$TARGET" in
		"patch")	patchSources	;;
		"llvm")		buildLLVM		;;
		"ldc")		buildLDC		;;
		"lwdr")		buildLWDR		;;
		"archive")  buildArchive	;;
		"clean")	clean			;;
		"all")
			clean
			patchSources
			buildLLVM
			buildLDC
			buildLWDR
			;;
		*)
			echo "Unknown target: '$TARGET'"
	esac
done
