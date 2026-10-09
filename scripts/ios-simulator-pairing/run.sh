#!/bin/zsh
# iOS companion check on an Xcode simulator, against a real roachnet-runtime.
#
#   scripts/ios-simulator-pairing/run.sh [path/to/roachnet-runtime]
#
# Runs the runtime (default: the packaged dist helper) with an isolated storage root,
# the companion lane on loopback and a fake local model lane. It builds the RoachNet-iOS
# working tree ($ROACHNET_IOS_REPO) for a throwaway simulator and drives it with XCUITest
# in phases, doing the desktop side in between:
#   1. pairing   roachnet://pair link, "Pair with RoachTail", desktop lists a connected peer
#   2. chat      a RoachClaw message reaches the model lane and the reply shows on the phone
#   3. org join  (desktop 1.1+) an Org invite link, "Ask to join", owner approves the join
#   4. org ok    (desktop 1.1+) the phone approves a pending board approval
# Phases a companion build doesn't support (no identifiers yet) are reported as skipped.
# The simulator, runtime and build output are removed afterwards; logs and screenshots
# stay in the work directory. Nothing touches real RoachNet storage or existing simulators.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}
RT=${1:-$REPO/native/macos/dist/RoachNet.app/Contents/Helpers/roachnet-runtime}
IOS=${ROACHNET_IOS_REPO:-${REPO:h}/RoachNet-iOS}
DEVICE=${ROACHNET_SIM_DEVICE:-iPhone 17 Pro}
RUNTIME_ID=${ROACHNET_SIM_RUNTIME:-$(xcrun simctl list runtimes | awk '/^iOS /{id=$NF} END{print id}')}
RT_PORT=${ROACHNET_SIM_RUNTIME_PORT:-38180}; BRIDGE_PORT=${ROACHNET_SIM_BRIDGE_PORT:-38181}; LANE_PORT=${ROACHNET_SIM_LANE_PORT:-38182}
W=${ROACHNET_SIM_WORKDIR:-$(mktemp -d -t roachnet-sim-pairing)}
[ -x "$RT" ] || { echo "roachnet-runtime not found: $RT"; exit 2; }
[ -d "$IOS/RoachNetCompanion.xcodeproj" ] || { echo "RoachNet-iOS not found: $IOS (set ROACHNET_IOS_REPO)"; exit 2; }
mkdir -p $W/home/tmp $W/storage
step() { echo "[sim-pairing] $1"; }
RPID=""; LPID=""; SIM=""; FAILED=0
API=http://127.0.0.1:$RT_PORT
cleanup() {
  [ -n "$SIM" ] && { xcrun simctl shutdown $SIM >/dev/null 2>&1; xcrun simctl delete $SIM >/dev/null 2>&1; }
  [ -n "$RPID" ] && { kill $RPID 2>/dev/null; sleep 1; kill -9 $RPID 2>/dev/null; }
  [ -n "$LPID" ] && kill $LPID 2>/dev/null
  # Keep logs and screenshots; drop the ~500 MB of build output unless asked to keep it.
  [ "${ROACHNET_SIM_KEEP_BUILD:-0}" = "1" ] || rm -rf $W/dd-app $W/dd-test
}
trap cleanup EXIT INT TERM
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}) or '')" "$1"; }

python3 $HERE/fake_model_lane.py $LANE_PORT $W/model-lane.jsonl > $W/model-lane.log 2>&1 &
LPID=$!
step "runtime $("$RT" --version) on 127.0.0.1:$RT_PORT, bridge :$BRIDGE_PORT, model lane :$LANE_PORT, work dir $W"
env HOME=$W/home TMPDIR=$W/home/tmp HOST=127.0.0.1 PORT=$RT_PORT URL=$API \
  ROACHNET_STORAGE_PATH=$W/storage ROACHNET_RUNTIME_STATE_ROOT=$W/storage/state/runtime-state \
  ROACHNET_LOCAL_BIN_PATH=$W/home/RoachNet/bin OLLAMA_BASE_URL=http://127.0.0.1:$LANE_PORT OPENCLAW_BASE_URL=http://127.0.0.1:13001 \
  ROACHNET_ROACHCLAW_DEFAULT_MODEL=sim-check:latest \
  ROACHNET_RUNTIME_KIND=native ROACHNET_NO_BROWSER=1 ROACHNET_DISABLE_QUEUE=1 ROACHNET_CONTAINERLESS_MODE=1 \
  ROACHNET_INSTALL_PROFILE=sim-pairing ROACHNET_BOOTSTRAP_PENDING=0 ROACHNET_COMPANION_ENABLED=1 \
  ROACHNET_COMPANION_HOST=127.0.0.1 ROACHNET_COMPANION_PORT=$BRIDGE_PORT ROACHNET_COMPANION_TOKEN=$(openssl rand -hex 32) \
  ROACHNET_COMPANION_ADVERTISED_URL=http://127.0.0.1:$BRIDGE_PORT ROACHTAIL_ENABLED=1 \
  "$RT" > $W/runtime.log 2>&1 &
RPID=$!
for i in {1..60}; do curl -sf $API/api/health >/dev/null && break; sleep 1; done
JOIN=$(curl -sS $API/api/companion/roachtail | json "d.get('joinCode')")
[ -n "$JOIN" ] || { echo "No RoachTail join code from the runtime"; exit 1; }

SIM=$(xcrun simctl create "RoachNet Pairing $$" "$DEVICE" "$RUNTIME_ID") || exit 1
step "simulator $DEVICE ($RUNTIME_ID) $SIM"
xcrun simctl boot $SIM && xcrun simctl bootstatus $SIM -b >/dev/null
step "building RoachNet-iOS and the UI tests"
xcodebuild -project $IOS/RoachNetCompanion.xcodeproj -scheme RoachNetCompanion -configuration Debug -sdk iphonesimulator \
  -destination "id=$SIM" -derivedDataPath $W/dd-app SYMROOT=$W/dd-app/sym OBJROOT=$W/dd-app/obj CODE_SIGNING_ALLOWED=NO build \
  > $W/ios-build.log 2>&1 || { tail -20 $W/ios-build.log; exit 1; }
APP=$(find $W/dd-app/sym/Debug-iphonesimulator -maxdepth 1 -name '*.app' | head -1)
xcrun simctl install $SIM "$APP" || exit 1
xcodebuild -project $HERE/SimPair.xcodeproj -scheme SimPair -sdk iphonesimulator -destination "id=$SIM" \
  -derivedDataPath $W/dd-test SYMROOT=$W/dd-test/sym OBJROOT=$W/dd-test/obj build-for-testing > $W/uitest-build.log 2>&1 \
  || { tail -20 $W/uitest-build.log; exit 1; }

# phase <name> <test method> [KEY=VALUE ...]  -> prints passed|skipped|failed
phase() {
  local name=$1 method=$2; shift 2
  local envs=(); for kv in "$@"; do envs+=("TEST_RUNNER_$kv"); done
  env "${envs[@]}" xcodebuild -project $HERE/SimPair.xcodeproj -scheme SimPair -sdk iphonesimulator -destination "id=$SIM" \
    -derivedDataPath $W/dd-test SYMROOT=$W/dd-test/sym OBJROOT=$W/dd-test/obj \
    -only-testing:SimPairUITests/PairingUITests/$method -resultBundlePath $W/$name.xcresult test-without-building > $W/$name.log 2>&1
  local rc=$?
  xcrun xcresulttool export attachments --path $W/$name.xcresult --output-path $W/screenshots/$name >/dev/null 2>&1
  if grep -q "skipped" $W/$name.log && grep -q "Test Case .*skipped" $W/$name.log; then echo skipped
  elif [ $rc -eq 0 ]; then echo passed
  else grep -E "error:" $W/$name.log | head -3 >&2; echo failed; fi
}
report() { step "$1: $2"; [ "$2" = failed ] && FAILED=1; }

PAIR_URL="roachnet://pair?bridgeUrl=http%3A%2F%2F127.0.0.1%3A$BRIDGE_PORT&joinCode=$JOIN"
R=$(phase 1-pairing test1PairWithRoachTail "PAIR_URL=$PAIR_URL")
STATUS=$(curl -sS $API/api/companion/roachtail | json "','.join(p.get('status','?') for p in d.get('peers',[]) if p.get('platform')=='ios')")
[[ "$STATUS" == *connected* ]] || R=failed
report "pairing (desktop iOS peers: ${STATUS:-none})" $R
[ $FAILED -eq 0 ] || { echo "iOS simulator check failed at pairing. Evidence: $W"; exit 1; }

R=$(phase 2-chat test2ChatRoundTrip "CHAT_PROMPT=Where is the water filter?" "CHAT_EXPECT=Sim check reply")
if [ "$R" = passed ] && ! grep -q "water filter" $W/model-lane.jsonl 2>/dev/null; then R=failed; fi
report "chat round trip" $R

if [ "$(curl -s -o /dev/null -w '%{http_code}' $API/api/org/me)" = 200 ]; then
  CID=$(curl -sS -X POST $API/api/org/companies -H 'Content-Type: application/json' -d '{"name":"Sim Check Co"}' | json "d['company']['id']")
  TOKEN=$(curl -sS -X POST $API/api/org/companies/$CID/invites -H 'Content-Type: application/json' -d '{"role":"admin"}' | json "d['token']")
  R=$(phase 3-org-join test3JoinOrg "ORG_INVITE_URL=roachnet://org-invite?token=$TOKEN")
  JR=$(curl -sS $API/api/org/companies/$CID/join-requests | json "next((j['id'] for j in d['joinRequests'] if j.get('status')=='pending_approval' and j.get('roachTailPeerId')), '')")
  if [ "$R" = passed ] && [ -z "$JR" ]; then R=failed; fi
  report "org join (request ${JR:-none})" $R
  if [ "$R" = passed ]; then
    curl -sS -X POST $API/api/org/companies/$CID/join-requests/$JR/approve -H 'Content-Type: application/json' -d '{}' >/dev/null
    AID=$(curl -sS -X POST $API/api/org/companies/$CID/approvals -H 'Content-Type: application/json' \
      -d '{"type":"request_board_approval","payload":{"title":"Simulator check approval","reason":"Proves approvals work from the phone."}}' | json "d['approval']['id']")
    R=$(phase 4-org-approve test4ApproveOrgRequest "ORG_APPROVAL_ID=$AID")
    DECIDED=$(curl -sS "$API/api/org/companies/$CID/approvals" | json "next((a['status']+'|'+(a.get('decisionNote') or '') for a in d['approvals'] if a['id']=='$AID'), '')")
    if [ "$R" = passed ] && [[ "$DECIDED" != approved* ]]; then R=failed; fi
    report "org approval ($AID: ${DECIDED:-missing})" $R
  fi
else
  step "org: skipped (this runtime has no RoachClaw Org)"
fi

if [ $FAILED -eq 0 ]; then
  echo "iOS companion check on the simulator is healthy. Evidence: $W"; exit 0
fi
echo "iOS simulator check failed. Evidence: $W"; exit 1
