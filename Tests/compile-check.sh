#!/bin/bash
# Off-device compile and link check for the tweak sources.
#
#   SDK=/path/to/iPhoneOSxx.x.sdk THEOS=/path/to/theos Tests/compile-check.sh
#
# Two things this catches that `Tests/run-tests.sh` cannot:
#
#   1. Compile errors under theos's own flags. theos builds with -Werror, so a
#      warning is fatal. Note -Wvla *and* -Wgnu-folding-constant: a
#      `static const size_t` used as an array bound is reported under the former
#      by some clangs and the latter by Apple's.
#   2. Link errors. Sources/*.xm are compiled as Objective-C++ and Sources/*.m
#      as Objective-C, so a free function declared without C linkage resolves to
#      a mangled name on one side and an unmangled one on the other. Only a real
#      object-file symbol check sees that; -fsyntax-only never will.
#
# Needs: clang able to target arm64-apple-ios (any platform), llvm-nm, an
# unpacked iOS SDK (github.com/theos/sdks), theos for its vendor headers, and
# logos.pl (github.com/theos/logos) to preprocess .xm/.x.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
SDK=${SDK:-}
THEOS=${THEOS:-}
LOGOS=${LOGOS:-${THEOS:+$THEOS/bin/logos.pl}}
OUT=${BUILD_DIR:-/tmp/uye-compile-check}

for required in SDK THEOS LOGOS; do
    if [ -z "${!required}" ]; then
        echo "SKIP: set \$$required (see the comment at the top of this script)"
        exit 0
    fi
done
[ -d "$SDK" ] || { echo "SKIP: \$SDK does not exist: $SDK"; exit 0; }
[ -f "$LOGOS" ] || { echo "SKIP: \$LOGOS does not exist: $LOGOS"; exit 0; }

rm -rf "$OUT"; mkdir -p "$OUT"
status=0
compiled=0

for f in Sources/*.xm Sources/*.x Sources/*.m; do
    base=$(basename "$f")
    src="$REPO/$f"
    lang=objective-c
    case "$f" in *.xm) lang=objective-c++ ;; esac
    case "$f" in
        *.xm|*.x)
            if ! perl "$LOGOS" "$REPO/$f" > "$OUT/$base.mm" 2>"$OUT/$base.logos"; then
                echo "LOGOS FAIL $f"; cat "$OUT/$base.logos"; status=1; continue
            fi
            src="$OUT/$base.mm" ;;
    esac

    if clang -c -x $lang -fobjc-arc -target arm64-apple-ios16.0 -isysroot "$SDK" \
        -I "$REPO/Tweaks" -I "$THEOS/vendor/include" -I "$REPO/Sources" -I "$REPO/Tweaks/RemoteLog" \
        -DTWEAK_VERSION='"check"' \
        -Werror -Wvla -Wgnu-folding-constant \
        -Wno-deprecated-declarations -Wno-unused-but-set-variable -Wno-error=format-security \
        "$src" -o "$OUT/$base.o" 2>"$OUT/$base.err"; then
        echo "OK   $f"
        compiled=$((compiled + 1))
    else
        echo "=== $f"
        head -20 "$OUT/$base.err"
        status=1
    fi
done

command -v llvm-nm >/dev/null || { echo "SKIP link check: llvm-nm not found"; exit $status; }
[ "$compiled" -gt 0 ] || exit $status

defined=$(llvm-nm --defined-only "$OUT"/*.o 2>/dev/null | awk '{print $NF}' | sort -u)
undefined=$(llvm-nm --undefined-only "$OUT"/*.o 2>/dev/null | awk '{print $NF}' | sort -u)
# A system framework symbol never contains "LF" followed by a capital, so
# anything left over here is one of this tweak's own functions.
unresolved=$(comm -23 <(echo "$undefined") <(echo "$defined") | grep -E 'LF[A-Z]')

if [ -n "$unresolved" ]; then
    echo "LINK: unresolved symbols from this tweak's own code (C/C++ linkage mismatch?):"
    echo "$unresolved" | sed 's/^/  /'
    status=1
else
    echo "LINK OK"
fi

exit $status
