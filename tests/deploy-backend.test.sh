#!/bin/bash
# Tests deploy-backend.sh's clean-checkout check and rollback guard with a
# stub gcloud/curl and a throwaway app repo. Nothing touches GCP.
# Run: bash tests/deploy-backend.test.sh
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-backend-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gcloud" <<'STUB'
#!/bin/bash
# Stateful stub: "run deploy --image=X" makes X the live image.
args="$*"
case "$args" in
  "run services describe"*"--format=value(status.url)"*) echo "https://svc.example" ;;
  "run services describe"*) [[ -f "$STUB_DIR/live_image" ]] || { echo "ERROR: (gcloud.run.services.describe) PERMISSION_DENIED" >&2; exit 1; }
                            cat "$STUB_DIR/live_image" ;;
  "builds submit"*) echo "$args" > "$STUB_DIR/built" ;;
  "run deploy"*) for a in "$@"; do if [[ "$a" == --image=* ]]; then echo "${a#--image=}" > "$STUB_DIR/live_image"; fi; done ;;
  "run services update-traffic"*) ;;
  "run jobs describe"*) exit 1 ;;
  *) ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/curl"
chmod +x "$WORK/bin/gcloud" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" STUB_DIR="$WORK"

APP="$WORK/app"
mkdir -p "$APP"
git -C "$APP" init -q -b main
git -C "$APP" config user.email t@example.com
git -C "$APP" config user.name test
echo 1 > "$APP/main.go"; git -C "$APP" add -A; git -C "$APP" commit -qm one
ONE="$(git -C "$APP" rev-parse --short HEAD)"
git -C "$APP" checkout -qb feature
echo 2 > "$APP/feature.go"; git -C "$APP" add -A; git -C "$APP" commit -qm "feature only"
FEATURE="$(git -C "$APP" rev-parse --short HEAD)"
git -C "$APP" checkout -q main
echo 3 > "$APP/main.go"; git -C "$APP" commit -qam two

run() { # run <expected 0|1> <description> [ENV=VAL...]
  local want="$1" desc="$2"; shift 2
  rm -f "$WORK/built"
  local code=0
  env "$@" APP_ROOT="$APP" GCP_PROJECT_ID=p CLEANUP_OLD_IMAGES=false CLEANUP_OLD_BUILDS=false \
    bash "$INFRA/deploy-backend.sh" >"$WORK/out.log" 2>&1 || code=$?
  if [[ ( "$want" == 0 && $code == 0 ) || ( "$want" == 1 && $code != 0 ) ]]; then echo "ok   $desc (exit $code)"
  else echo "FAIL $desc: exit $code"; sed 's/^/     /' "$WORK/out.log"; FAILS=$((FAILS+1)); fi
}
live() { echo "gcr.io/p/feedseeker-website:$1" > "$WORK/live_image"; }

live "${ONE}-20261105000000"
run 0 "deploys when live is an ancestor of HEAD"
grep -q "feedseeker-website:$(git -C "$APP" rev-parse --short HEAD)-" "$WORK/live_image" && echo "ok   image tag carries HEAD's commit" || { echo "FAIL image tag"; cat "$WORK/live_image"; FAILS=$((FAILS+1)); }

live "${FEATURE}-20261105000000"
run 1 "refuses to drop a feature branch production runs (the 318a4f2 case)"
grep -q "feature only" "$WORK/out.log" && echo "ok   names the commit it would drop" || { echo "FAIL missing list"; FAILS=$((FAILS+1)); }
[[ ! -f "$WORK/built" ]] && echo "ok   nothing built" || { echo "FAIL built despite guard"; FAILS=$((FAILS+1)); }
run 0 "FORCE=true rolls back on purpose" FORCE=true

live "abcdef1-20261105000000"
run 1 "refuses when live commit isn't in the repo"

live "deadbee"
echo "gcr.io/p/feedseeker-website@sha256:$(printf '%064d' 0)" > "$WORK/live_image"
run 0 "digest-pinned live image: guard skipped with a note"

rm -f "$WORK/live_image"
run 1 "refuses when the live service can't be read"

live "${ONE}-20261105000000"
echo dirty >> "$APP/main.go"
run 1 "refuses uncommitted changes"
run 0 "ALLOW_DIRTY=true overrides" ALLOW_DIRTY=true
git -C "$APP" checkout -q -- main.go
touch "$APP/untracked.txt"
run 1 "refuses untracked files (they'd be rsynced into the image)"
rm "$APP/untracked.txt"

echo
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; fi
echo "all deploy-backend tests passed"
