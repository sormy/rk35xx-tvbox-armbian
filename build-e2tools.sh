#!/usr/bin/env bash
# Build patched e2tools into tools/e2tools (gitignored). build-image.sh puts that directory ahead of
# PATH, so every e2cp/e2rm in the build uses these and never the stock ones.
#
# Usage: ./build-e2tools.sh            # fetch, patch, build, self-test
#        ./build-e2tools.sh --test     # re-run the self-test against what is already built
#
# Stock e2tools cannot safely edit an image: deleting a symlink frees its target string as block
# numbers, and removing a directory leaks the inode. Both corrupt the rootfs, both are silent until
# the box mounts it read-only. patches/e2tools/ fixes them and implements `e2ln -s`, which upstream
# has always answered with "Not implemented yet". Upstream's own suite is one test that never
# deletes anything, so the gate below is ours.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$REPO/tools"                               # gitignored output dir
BUILD="$TOOLS/src/e2tools"                        # scratch clone
OUT="$TOOLS/e2tools"                              # the binaries build-image.sh picks up
PATCHES="$REPO/patches/e2tools"

# --- pinned dependency (bump deliberately, never float) ---
E2TOOLS_REPO="https://github.com/e2tools/e2tools.git"
E2TOOLS_VERSION="v0.1.2"

TOOLNAMES="e2cp e2ls e2ln e2mkdir e2mv e2rm e2tail"

need() { command -v "$1" >/dev/null || { echo "missing: $1 — $2"; exit 1; }; }

# e2fsprogs supplies both libext2fs (to build against) and mke2fs/debugfs/fsck.ext4 (to test with).
# Homebrew keeps it keg-only, so it is on no default search path.
for p in /opt/homebrew/opt/e2fsprogs /usr/local/opt/e2fsprogs; do
	[ -d "$p" ] && { export PKG_CONFIG_PATH="$p/lib/pkgconfig:${PKG_CONFIG_PATH:-}"; PATH="$p/sbin:$p/bin:$PATH"; break; }
done
export PATH

# --- the gate: prove the tool cannot corrupt an image before anything uses it ---
selftest() {
	local img tmp fail=0
	for t in mke2fs fsck.ext4 debugfs; do need "$t" "install e2fsprogs"; done
	[ -x "$OUT/e2rm" ] || { echo "nothing built yet — run $0 first"; exit 1; }

	tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
	img="$tmp/t.img"
	local short="/lib/systemd/system/serial-getty@.service"
	local long="$short.padded.out.past.sixty.bytes.to.force.the.slow.form"
	head -c 40960 /dev/urandom > "$tmp/payload"

	fresh() { rm -f "$img"; head -c 16777216 /dev/zero > "$img"; mke2fs -q -t ext4 -F "$img"; }
	# every case must land back on the byte count of an untouched filesystem: a leak shows up as a
	# higher count, a double-free as an fsck complaint
	fresh; local base; base="$(fsck.ext4 -fn "$img" 2>&1 | tail -1 | sed 's/.*), //')"

	check() {
		local what="$1" out
		out="$(fsck.ext4 -fn "$img" 2>&1)"
		local now; now="$(printf '%s' "$out" | tail -1 | sed 's/.*), //')"
		if printf '%s' "$out" | grep -qE 'differences|Unconnected|WARNING|wrong'; then
			printf '  FAIL  %-22s %s\n' "$what" "$(printf '%s' "$out" | grep -m1 -E 'differences|Unconnected|wrong')"; fail=1
		elif [ "$now" != "$base" ]; then
			printf '  FAIL  %-22s leaked: %s vs %s\n' "$what" "$now" "$base"; fail=1
		else
			printf '  PASS  %-22s %s\n' "$what" "$now"
		fi
	}

	fresh; "$OUT/e2cp" "$tmp/payload" "$img:/f" >/dev/null; "$OUT/e2rm" "$img:/f";            check "rm regular file"
	fresh; "$OUT/e2ln" -s "$short" "$img:/L";              "$OUT/e2rm" "$img:/L";            check "rm fast symlink"
	fresh; "$OUT/e2ln" -s "$long"  "$img:/L";              "$OUT/e2rm" "$img:/L";            check "rm slow symlink"
	fresh; "$OUT/e2mkdir" "$img:/d" >/dev/null; "$OUT/e2cp" "$tmp/payload" "$img:/d/f" >/dev/null
	       "$OUT/e2rm" -r "$img:/d";                                                         check "rm -r directory"
	fresh; "$OUT/e2mkdir" "$img:/a" >/dev/null; "$OUT/e2mkdir" "$img:/a/b" >/dev/null
	       "$OUT/e2cp" "$tmp/payload" "$img:/a/b/f" >/dev/null; "$OUT/e2rm" -r "$img:/a";     check "rm -r nested"

	# and the symlink must survive as a symlink, not just leave fsck quiet
	fresh; "$OUT/e2ln" -s "$short" "$img:/L"
	if [ "$(debugfs -R "stat /L" "$img" 2>/dev/null | sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p')" = "$short" ]; then
		printf '  PASS  %-22s target reads back\n' "e2ln -s"
	else
		printf '  FAIL  %-22s target wrong or missing\n' "e2ln -s"; fail=1
	fi

	[ "$fail" = 0 ] || { echo "self-test failed — not safe to edit images with this build"; return 1; }
	echo "e2tools verified: deletes leave the filesystem byte-identical to untouched"
}

if [ "${1:-}" = "--test" ]; then selftest; exit; fi

case "$(uname -s)" in
	Darwin)
		need brew "install Homebrew first"
		for p in autoconf automake libtool pkg-config e2fsprogs; do
			brew list --formula "$p" >/dev/null 2>&1 || brew install "$p"
		done
		;;
	Linux)
		for c in autoreconf pkg-config cc; do need "$c" "apt install autoconf automake libtool pkg-config gcc e2fsprogs"; done
		pkg-config --exists ext2fs || { echo "missing: libext2fs — apt install e2fsprogs libext2fs-dev"; exit 1; }
		;;
	*) echo "unsupported host: $(uname -s)"; exit 1 ;;
esac

mkdir -p "$TOOLS/src" "$OUT"
if [ -d "$BUILD/.git" ]; then
	git -C "$BUILD" fetch --quiet --tags origin || true
else
	rm -rf "$BUILD"
	git clone --quiet "$E2TOOLS_REPO" "$BUILD"
fi
# discard the previous run's patches before reapplying, so a rebuild is not cumulative
git -C "$BUILD" checkout --quiet --force "$E2TOOLS_VERSION"
git -C "$BUILD" clean -qfd

for p in "$PATCHES"/*.patch; do
	echo "  PATCH $(basename "$p")"
	git -C "$BUILD" apply "$p" || { echo "patch did not apply — e2tools $E2TOOLS_VERSION may have moved"; exit 1; }
done

cd "$BUILD"
autoreconf -i >/dev/null 2>&1
./configure --quiet >/dev/null
# upstream builds with a warning of its own; keep the log and show it only if the build fails
make -j"$(getconf _NPROCESSORS_ONLN)" >build.log 2>&1 || { tail -20 build.log; exit 1; }

# one binary that dispatches on argv[0]; the tool names are links to it, as the install would make
install -m 755 "$BUILD/e2tools" "$OUT/e2tools"
for t in $TOOLNAMES; do ln -sf e2tools "$OUT/$t"; done

echo "built: tools/e2tools/{$(echo "$TOOLNAMES" | tr ' ' ',')}  (e2tools $E2TOOLS_VERSION + $(ls -1 "$PATCHES"/*.patch | wc -l | tr -d ' ') patches)"
selftest
