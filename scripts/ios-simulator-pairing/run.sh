#!/bin/zsh
# RoachTail pairing check for the iOS companion on an Xcode simulator.
#
#   scripts/ios-simulator-pairing/run.sh [path/to/roachnet-runtime]
#
# Runs the given roachnet-runtime (default: the packaged dist helper) with an isolated
# storage root and the companion lane on loopback. It builds the RoachNet-iOS working
# tree ($ROACHNET_IOS_REPO) for a throwaway simulator, opens the roachnet://pair deep
# link, and presses "Pair with RoachTail" from an XCUITest. It then checks that the
# desktop lists the phone as a connected peer. The simulator and runtime are removed
# afterwards. Nothing touches real RoachNet storage or existing simulators.
set -u
HERE=${0:A:h}; REPO=${HERE:h:h}
RT=${1:-$REPO/native/macos/dist/RoachNet.app/Contents/Helpers/roachnet-runtime}
IOS=${ROACHNET_IOS_REPO:-${REPO:h}/RoachNet-iOS}
DEVICE=${ROACHNET_SIM_DEVICE:-iPhone 17 Pro}
RUNTIME_ID=${ROACHNET_SIM_RUNTIME:-$(xcrun simctl list runtimes | awk '/^iOS /{id=$NF} END{print id}')}
RT_PORT=${ROACHNET_SIM_RUNTIME_PORT:-38180}; BRIDGE_PORT=${ROACHNET_SIM_BRIDGE_PORT:-38181}
W=${ROACHNET_SIM_WORKDIR:-$(mktemp -d -t roachnet-sim-pairing)}
[ -x "$RT" ] || { echo "roachnet-runtime not found: $RT"; exit 2; }
[ -d "$IOS/RoachNetCompanion.xcodeproj" ] || { echo "RoachNet-iOS not found: $IOS (set ROACHNET_IOS_REPO)"; exit 2; }
mkdir -p $W/home/tmp $W/storage
step() { echo "[sim-pairing] $1"; }
RPID=""; SIM=""
cleanup() {
  [ -n "$SIM" ] && { xcrun simctl shutdown $SIM >/dev/null 2>&1; xcrun simctl delete $SIM >/dev/null 2>&1; }
  [ -n "$RPID" ] && { kill $RPID 2>/dev/null; sleep 1; kill -9 $RPID 2>/dev/null; }
  # Keep logs and screenshots; drop the ~500 MB of build output unless asked to keep it.
  [ "${ROACHNET_SIM_KEEP_BUILD:-0}" = "1" ] || rm -rf $W/dd-app $W/dd-test
}
trap cleanup EXIT INT TERM

step "runtime $("$RT" --version) on 127.0.0.1:$RT_PORT, bridge :$BRIDGE_PORT, work dir $W"
env HOME=$W/home TMPDIR=$W/home/tmp HOST=127.0.0.1 PORT=$RT_PORT URL=http://127.0.0.1:$RT_PORT \
  ROACHNET_STORAGE_PATH=$W/storage ROACHNET_RUNTIME_STATE_ROOT=$W/storage/state/runtime-state \
  ROACHNET_LOCAL_BIN_PATH=$W/home/RoachNet/bin OLLAMA_BASE_URL=http://127.0.0.1:36434 OPENCLAW_BASE_URL=http://127.0.0.1:13001 \
  ROACHNET_RUNTIME_KIND=native ROACHNET_NO_BROWSER=1 ROACHNET_DISABLE_QUEUE=1 ROACHNET_CONTAINERLESS_MODE=1 \
  ROACHNET_INSTALL_PROFILE=sim-pairing ROACHNET_BOOTSTRAP_PENDING=0 ROACHNET_COMPANION_ENABLED=1 \
  ROACHNET_COMPANION_HOST=127.0.0.1 ROACHNET_COMPANION_PORT=$BRIDGE_PORT ROACHNET_COMPANION_TOKEN=$(openssl rand -hex 32) \
  ROACHNET_COMPANION_ADVERTISED_URL=http://127.0.0.1:$BRIDGE_PORT ROACHTAIL_ENABLED=1 \
  "$RT" > $W/runtime.log 2>&1 &
RPID=$!
for i in {1..60}; do curl -sf http://127.0.0.1:$RT_PORT/api/health >/dev/null && break; sleep 1; done
JOIN=$(curl -sS http://127.0.0.1:$RT_PORT/api/companion/roachtail | python3 -c "import json,sys; print(json.load(sys.stdin).get('joinCode') or '')")
[ -n "$JOIN" ] || { echo "No RoachTail join code from the runtime"; exit 1; }

SIM=$(xcrun simctl create "RoachNet Pairing $$" "$DEVICE" "$RUNTIME_ID") || exit 1
step "simulator $DEVICE ($RUNTIME_ID) $SIM"
xcrun simctl boot $SIM && xcrun simctl bootstatus $SIM -b >/dev/null
step "building RoachNet-iOS for the simulator"
xcodebuild -project $IOS/RoachNetCompanion.xcodeproj -scheme RoachNetCompanion -configuration Debug -sdk iphonesimulator \
  -destination "id=$SIM" -derivedDataPath $W/dd-app SYMROOT=$W/dd-app/sym OBJROOT=$W/dd-app/obj CODE_SIGNING_ALLOWED=NO build \
  > $W/ios-build.log 2>&1 || { tail -20 $W/ios-build.log; exit 1; }
APP=$(find $W/dd-app/sym/Debug-iphonesimulator -maxdepth 1 -name '*.app' | head -1)
xcrun simctl install $SIM "$APP" || exit 1

step "pairing through the UI"
PAIR_URL="roachnet://pair?bridgeUrl=http%3A%2F%2F127.0.0.1%3A$BRIDGE_PORT&joinCode=$JOIN"
TEST_RUNNER_PAIR_URL="$PAIR_URL" xcodebuild -project $HERE/SimPair.xcodeproj -scheme SimPair -sdk iphonesimulator \
  -destination "id=$SIM" -derivedDataPath $W/dd-test SYMROOT=$W/dd-test/sym OBJROOT=$W/dd-test/obj \
  -resultBundlePath $W/uitest.xcresult test > $W/uitest.log 2>&1
UI_RC=$?
grep -E "error:|Test Case .*(passed|failed)" $W/uitest.log | tail -5
xcrun xcresulttool export attachments --path $W/uitest.xcresult --output-path $W/screenshots >/dev/null 2>&1

STATUS=$(curl -sS http://127.0.0.1:$RT_PORT/api/companion/roachtail | python3 -c "
import json,sys; peers=json.load(sys.stdin).get('peers',[])
print(','.join(p.get('status','?') for p in peers if p.get('platform')=='ios'))")
step "desktop iOS peers: ${STATUS:-none}"
if [ $UI_RC -eq 0 ] && [[ "$STATUS" == *connected* ]]; then
  echo "iOS companion RoachTail pairing on the simulator is healthy. Evidence: $W"; exit 0
fi
echo "iOS simulator pairing failed. Evidence: $W"; exit 1
