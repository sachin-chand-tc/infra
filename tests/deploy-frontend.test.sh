#!/bin/bash
# Tests deploy-frontend.sh's state detection, rollback guard, metadata and
# deploy marker against a throwaway webinputs repo and a stub gcloud.
# Nothing touches real GCS. Run: bash tests/deploy-frontend.test.sh
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-frontend-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

# ── Stub gcloud: objects describe reads $WORK/live.json, cp records its args ──
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gcloud" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "storage objects")
    [[ -f "$STUB_DIR/live.json" ]] || { echo "ERROR: not found" >&2; exit 1; }
    cat "$STUB_DIR/live.json" ;;
  "storage cp")
    printf '%s\n' "$@" > "$STUB_DIR/cp-args"
    cp "$3" "$STUB_DIR/uploaded.tar.gz" ;;
  *) echo "stub gcloud: unexpected $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH" STUB_DIR="$WORK" CI=""

# ── Throwaway webinputs repo: main with two planner commits, a branch with a third ──
REPO="$WORK/webinputs"
mkdir -p "$REPO/planner" "$REPO/common" "$REPO/sachins"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
echo v1 > "$REPO/planner/index.html"; echo c > "$REPO/common/auth.js"; echo s > "$REPO/sachins/index.html"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "planner v1"
C1="$(git -C "$REPO" rev-parse HEAD)"
T1="$(git -C "$REPO" rev-parse HEAD:planner)+$(git -C "$REPO" rev-parse HEAD:common)"
echo v2 > "$REPO/planner/index.html"
git -C "$REPO" commit -qam "planner v2"
C2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -qb feature
echo v3 > "$REPO/planner/index.html"
git -C "$REPO" commit -qam "planner v3 (only on feature)"
C3="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
echo s2 > "$REPO/sachins/index.html"
git -C "$REPO" commit -qam "sachins only"
C4="$(git -C "$REPO" rev-parse HEAD)"
T4="$(git -C "$REPO" rev-parse HEAD:planner)+$(git -C "$REPO" rev-parse HEAD:common)"

live() { # live <commit> <tree>
  printf '{"name":"planner.tar.gz","generation":"1","custom_fields":{"commit":"%s","source_tree":"%s"}}' "$1" "$2" > "$WORK/live.json"
}
check_state() { # check_state <expected> <description>
  local got
  got="$(WEBINPUTS_ROOT="$REPO" bash "$INFRA/deploy-frontend.sh" --site planner --check 2>/dev/null | sed -n 's/^state=//p')"
  if [[ "$got" == "$1" ]]; then echo "ok   $2 → $got"; else echo "FAIL $2: expected $1, got $got"; FAILS=$((FAILS+1)); fi
}
publish() { # publish <args...>; returns the script's exit code
  rm -f "$WORK/cp-args" "$WORK/uploaded.tar.gz"
  WEBINPUTS_ROOT="$REPO" bash "$INFRA/deploy-frontend.sh" --site planner "$@" >"$WORK/out.log" 2>&1
}
expect() { # expect <0|1> <description> <args...>
  local want="$1" desc="$2"; shift 2
  local code=0; publish "$@" || code=$?
  if [[ ( "$want" == 0 && $code == 0 ) || ( "$want" == 1 && $code != 0 ) ]]; then echo "ok   $desc (exit $code)"
  else echo "FAIL $desc: exit $code"; sed 's/^/     /' "$WORK/out.log"; FAILS=$((FAILS+1)); fi
}

rm -f "$WORK/live.json"
check_state missing "no archive yet"
echo '{"name":"planner.tar.gz","generation":"1"}' > "$WORK/live.json"
check_state unknown "archive without metadata"
live "$C4" "$T4"
check_state current "live built from the same tree"
live "$C1" "$T1"
check_state ahead "live is an ancestor of main"
live "$C3" "x"
check_state behind "live has a planner commit main lacks (the 2026-11-06 rollback)"
live "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "x"
check_state foreign "live commit not in this repo"

# Live built from a branch off main whose extra commit only touches sachins:
# publishing main loses nothing on planner, so it's not a rollback.
git -C "$REPO" checkout -q "$C2"
git -C "$REPO" checkout -qb feature-sachins
echo s3 > "$REPO/sachins/index.html"; git -C "$REPO" commit -qam "sachins on feature"
git -C "$REPO" checkout -q main
live "$(git -C "$REPO" rev-parse feature-sachins)" "x"
check_state ahead "live's extra commits don't touch planner or common"

# ── Publishing ──
live "$C3" "x"
expect 1 "refuses to roll planner back"
grep -q "planner v3 (only on feature)" "$WORK/out.log" && echo "ok   names the commit it would lose" || { echo "FAIL missing-commit list"; FAILS=$((FAILS+1)); }
[[ ! -f "$WORK/cp-args" ]] && echo "ok   nothing uploaded" || { echo "FAIL uploaded despite guard"; FAILS=$((FAILS+1)); }
expect 0 "--force publishes anyway" --force

live "$C1" "$T1"
expect 0 "publishes when ahead"
grep -q -- "--custom-metadata=commit=${C4},source_tree=${T4},ref=main," "$WORK/cp-args" && echo "ok   records commit, tree and ref" || { echo "FAIL metadata"; cat "$WORK/cp-args"; FAILS=$((FAILS+1)); }
mkdir -p "$WORK/x" && tar -xzf "$WORK/uploaded.tar.gz" -C "$WORK/x"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["commit"]==sys.argv[2] and d["site"]=="planner", d' "$WORK/x/__deploy.json" "$C4" \
  && echo "ok   archive carries __deploy.json" || { echo "FAIL marker"; FAILS=$((FAILS+1)); }
[[ -f "$WORK/x/common/auth.js" && -f "$WORK/x/index.html" ]] && echo "ok   archive has site + common/" || { echo "FAIL archive layout"; FAILS=$((FAILS+1)); }

echo dirty >> "$REPO/planner/index.html"
expect 1 "refuses uncommitted planner changes locally"
expect 0 "--allow-dirty overrides" --allow-dirty
CI=true expect 0 "CI skips the dirty check"
git -C "$REPO" checkout -q -- planner

# Not a git checkout (a hand-staged folder): needs DEPLOY_COMMIT or --force.
STAGE="$WORK/stage"; mkdir -p "$STAGE/planner" "$STAGE/common"; echo v > "$STAGE/planner/index.html"
code=0; WEBINPUTS_ROOT="$STAGE" bash "$INFRA/deploy-frontend.sh" --site planner >"$WORK/out.log" 2>&1 || code=$?
[[ $code != 0 ]] && echo "ok   staged folder without DEPLOY_COMMIT is refused" || { echo "FAIL staged folder accepted"; FAILS=$((FAILS+1)); }

# instascraper uploads to the object the server reads.
mkdir -p "$REPO/instascraper"; echo i > "$REPO/instascraper/index.html"; git -C "$REPO" add -A; git -C "$REPO" commit -qm insta
rm -f "$WORK/live.json"
WEBINPUTS_ROOT="$REPO" bash "$INFRA/deploy-frontend.sh" --site instascraper >"$WORK/out.log" 2>&1
grep -q '^gs://starkindustries-og-static-an1/insta-scraper.tar.gz$' "$WORK/cp-args" && echo "ok   instascraper → insta-scraper.tar.gz" || { echo "FAIL instascraper object"; cat "$WORK/cp-args"; FAILS=$((FAILS+1)); }

echo
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; fi
echo "all deploy-frontend tests passed"
