#!/bin/bash
# Check that `make app` hands a signing identity to xcodebuild as ONE argument,
# whatever its name holds. An Apple identity looks like
# "Apple Development: Your Name (TEAMID)": spaces, a colon and parentheses,
# which an unquoted value turns into a shell syntax error.
#
# Runs a copy of the Makefile against stub `xcodebuild` and `security` tools,
# so it builds nothing and never reads the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp Makefile "$work/Makefile"
mkdir "$work/bin" "$work/GhosttyKit.xcframework"

# The stub records each argument on its own line.
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$SELFTEST_ARGS"
STUB
# The stub keychain holds exactly the identities named in SELFTEST_IDENTITIES.
cat > "$work/bin/security" <<'STUB'
#!/bin/bash
printf '%s\n' "$SELFTEST_IDENTITIES"
STUB
chmod +x "$work/bin/xcodebuild" "$work/bin/security"

fail=0
check() {  # check <label> <identity> <keychain contents> <expected argument>
  local label=$1 identity=$2 keychain=$3 expected=$4
  export SELFTEST_ARGS="$work/args" SELFTEST_IDENTITIES="$keychain"
  rm -f "$SELFTEST_ARGS"
  if ! PATH="$work/bin:$PATH" make -s -C "$work" app SIGN_IDENTITY="$identity" \
      > "$work/out" 2>&1; then
    echo "FAIL $label: make app failed"; sed 's/^/    /' "$work/out"; fail=1; return
  fi
  if grep -qxF -- "$expected" "$SELFTEST_ARGS"; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected the argument '$expected', got:"
    grep MM_CODE_SIGN_IDENTITY "$SELFTEST_ARGS" | sed 's/^/    /' || true
    fail=1
  fi
}

apple='Apple Development: Your Name (TEAMID)'
hash='0123456789ABCDEF0123456789ABCDEF01234567'
listing="  1) $hash \"$apple\""

check "plain name"            'MuxMaestro-Local' '  1) AAAA "MuxMaestro-Local"' 'MM_CODE_SIGN_IDENTITY=MuxMaestro-Local'
check "spaces and parentheses" "$apple" "$listing" "MM_CODE_SIGN_IDENTITY=$apple"
check "SHA-1 hash"            "$hash"  "$listing" "MM_CODE_SIGN_IDENTITY=$hash"
# A name that is a regular expression must match as text, not as a pattern.
check "not in the keychain"   'Apple Development: .* (TEAMID)' "$listing" 'MM_CODE_SIGN_IDENTITY=-'
check "single quote in name"  "Apple Development: Pat O'Neil (TEAMID)" \
  "  1) $hash \"Apple Development: Pat O'Neil (TEAMID)\"" \
  "MM_CODE_SIGN_IDENTITY=Apple Development: Pat O'Neil (TEAMID)"

exit $fail
