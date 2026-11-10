#!/usr/bin/env bash
# Observe what the iOS globe (input mode) menu shows for the Songyan keyboard extension
# while the simulator really runs in Japanese / Traditional Chinese (Taiwan, Hong Kong).
#
# Purpose: reproducible evidence for the localization work. The system language is changed
# through the simulator's own cfprefsd and applied by a reboot, so the observation is of a
# real system preference, not of a per-launch -AppleLanguages argument. Each run records the
# keyboard name and the language label iOS derives from the extension's PrimaryLanguage, a
# screenshot of the menu, and the preferences read back after the reboot.
#
# Usage:
#   observe-keyboard-system-locales.sh --save-baseline
#   observe-keyboard-system-locales.sh --apply <a,b> <locale-id> <tag>
#   observe-keyboard-system-locales.sh --menu-shot <tag> <index>
#   observe-keyboard-system-locales.sh --system-shot <tag> <index>
#   observe-keyboard-system-locales.sh --restore
#
# Options (before the mode):
#   --udid UDID     Target simulator (default: the one named Songyan-I18n)
#   --device NAME   Device name to resolve when --udid is absent
#   --host BUNDLE   Host app bundle id (default app.songyan.ime)
#
# Output: screenshots in .scratch/system-locales, JSON logs in .local/system-locales.

set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
UDID="${UDID:-}"
DEVICE_NAME="Songyan-I18n"
HOST_BUNDLE="app.songyan.ime"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SHOTS="${ROOT}/.scratch/system-locales"
LOGS="${ROOT}/.local/system-locales"
mkdir -p "${SHOTS}" "${LOGS}"

# WHY: the accessibility tree is per-run scratch data. Keeping it beside the other evidence
# keeps the worktree self-contained (no shared /tmp file another session could clobber), and
# the trap makes sure no scratch file survives the run.
TREE="${SHOTS}/.observe-tree.json"
trap 'rm -f "${TREE}"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --device) DEVICE_NAME="$2"; shift 2 ;;
    --host) HOST_BUNDLE="$2"; shift 2 ;;
    *) break ;;
  esac
done
MODE="${1:-}"; [[ -n "${MODE}" ]] || { echo "missing mode" >&2; exit 64; }; shift

if [[ -z "${UDID}" ]]; then
  UDID="$(xcrun simctl list devices -j | python3 -c '
import json,sys
name=sys.argv[1]
for runtime in json.load(sys.stdin)["devices"].values():
    for d in runtime:
        if d["name"]==name and d["isAvailable"]:
            print(d["udid"]); raise SystemExit
' "${DEVICE_NAME}")"
fi
[[ -n "${UDID}" ]] || { echo "no simulator named ${DEVICE_NAME}" >&2; exit 1; }

sim() { xcrun simctl "$@"; }

# WHY: cfprefsd serves cached values, so host-side edits are invisible to the simulator;
# both reads and writes go through the simulator's own defaults.
langs_read() {
  sim spawn "${UDID}" defaults read -g AppleLanguages \
    | tr -d '(),"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | paste -sd, -
}
locale_read() { sim spawn "${UDID}" defaults read -g AppleLocale; }

# WHY: DEBUG.md section 5 documents that AXe can answer "No translation object returned"
# after a reboot; restarting the simulator's bridge makes the next dump work.
dump_tree() {
  axe describe-ui --udid "${UDID}" >"${TREE}" 2>/dev/null || true
  if [[ ! -s "${TREE}" ]] || [[ "$(head -c 1 "${TREE}")" != "[" ]]; then
    sim spawn "${UDID}" launchctl kickstart -k user/foreground/com.apple.CoreSimulator.bridge 2>/dev/null || true
    sleep 2
    axe describe-ui --udid "${UDID}" >"${TREE}" 2>/dev/null || true
  fi
  [[ "$(head -c 1 "${TREE}")" == "[" ]] || { echo "describe-ui returned no tree" >&2; return 1; }
}

# Prints the centre of the element the mode names, as "x y", read from the current tree.
# WHY: coordinates are always measured from the live UI, never remembered across reboots.
ui_centre() {
  python3 - "$1" "${TREE}" <<'PY'
import json,sys
mode,path=sys.argv[1],sys.argv[2]
tree=json.load(open(path))
W,H=402.0,874.0
hits=[]
def walk(n):
    if isinstance(n,list):
        for c in n: walk(c)
        return
    if not isinstance(n,dict): return
    f=n.get('frame') or {}
    if mode=="textfield":
        if n.get('type')=='TextArea' and f.get('width',0)>100: hits.append(f)
    elif mode=="tryrow":
        # The home row is one wide button whose label starts with the page title.
        if f.get('width',0)>300 and (n.get('AXLabel') or '').startswith('试打'): hits.append(f)
    elif mode=="globe":
        # The globe key is the only button in the bottom-left corner of the keyboard window.
        if n.get('type')=='Button' and f.get('x',999)<0.2*W and f.get('y',0)>0.9*H: hits.append(f)
    for c in (n.get('children') or []): walk(c)
walk(tree)
if hits:
    f=hits[0]
    print("%.0f %.0f" % (f['x']+f['width']/2, f['y']+f['height']/2))
PY
}

# WHY: the first frames of a freshly launched app are blank and PNG size does not prove the
# window has content, so readiness is read from the accessibility tree: the Settings app is
# frontmost when the host app's markers are gone and several labelled rows exist below the
# status bar. Bounded so a stuck launch fails instead of hanging.
system_ready() {
  python3 - "${TREE}" <<'PY'
import json,sys
tree=json.load(open(sys.argv[1]))
labeled=[];host=0
def walk(n):
    global host
    if isinstance(n,list):
        for c in n: walk(c)
        return
    if not isinstance(n,dict): return
    f=n.get('frame') or {}
    label=n.get('AXLabel') or ''
    if n.get('type')=='TextArea': host+=1
    if label.startswith('试打'): host+=1
    if label and f.get('y',0)>150 and f.get('width',0)>60 and f.get('height',0)>=20:
        labeled.append(label)
    for c in (n.get('children') or []): walk(c)
walk(tree)
print("yes" if host==0 and len(labeled)>=3 else "no")
PY
}

reboot() {
  sim shutdown "${UDID}"
  sim boot "${UDID}"
  sim bootstatus "${UDID}" -b >/dev/null
}

# WHY: an explicit call means "capture what the simulator runs now". Reusing a baseline from
# an earlier experiment would silently restore the wrong language, so this always overwrites.
save_baseline() {
  local f="${LOGS}/baseline.json"
  python3 - "${f}" "${UDID}" "$(langs_read)" "$(locale_read)" \
    "$(sim spawn "${UDID}" defaults read -g AppleKeyboards | tr -d '(),"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | paste -sd'|' -)" <<'PY'
import json,sys,datetime
f,udid,langs,locale,keyboards=sys.argv[1:6]
json.dump({"capturedAt":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "udid":udid,"AppleLanguages":langs.split(","),"AppleLocale":locale,
           "AppleKeyboards":keyboards.split("|")},open(f,"w"),ensure_ascii=False,indent=2)
PY
  cat "${f}"
}

apply_lang() {
  local list="$1" locale="$2" tag="$3"
  local before; before="$(langs_read)"
  local first="${list%%,*}"
  # Red assertion: if the system already runs the target language the capture could be stale,
  # so the run must start from a different language.
  if [[ "${before%%,*}" == "${first}" ]]; then
    echo "already ${first}; refusing to observe a language that was not freshly applied" >&2
    exit 3
  fi
  local -a parts; IFS=',' read -r -a parts <<<"${list}"
  sim spawn "${UDID}" defaults write -g AppleLanguages -array "${parts[@]}"
  sim spawn "${UDID}" defaults write -g AppleLocale -string "${locale}"
  sim spawn "${UDID}" killall -u "$(id -u)" cfprefsd 2>/dev/null || true
  reboot
  local after after_locale
  after="$(langs_read)"; after_locale="$(locale_read)"
  # Green assertion: every entry must survive the reboot; a partial write still switches
  # some system UI and would make the observation ambiguous.
  if [[ "${after}" != "${list}" || "${after_locale}" != "${locale}" ]]; then
    echo "language did not stick: wrote ${list}/${locale}, read ${after}/${after_locale}" >&2
    exit 4
  fi
  python3 - "${LOGS}/${tag}-prefs.json" "${tag}" "${before}" "${after}" "${after_locale}" <<'PY'
import json,sys,datetime
f,tag,before,after,locale=sys.argv[1:6]
json.dump({"tag":tag,"capturedAt":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "AppleLanguagesBefore":before.split(","),"AppleLanguagesAfterReboot":after.split(","),
           "AppleLocaleAfterReboot":locale,
           "verdict":"system preference applied and survived reboot"},open(f,"w"),ensure_ascii=False,indent=2)
PY
  cat "${LOGS}/${tag}-prefs.json"
}

menu_shot() {
  local tag="$1" index="${2:-0}"
  sim terminate "${UDID}" "${HOST_BUNDLE}" >/dev/null 2>&1 || true
  sim launch "${UDID}" "${HOST_BUNDLE}" >/dev/null
  sleep 3
  dump_tree
  local row; row="$(ui_centre tryrow)"
  if [[ -z "$(ui_centre textfield)" && -n "${row}" ]]; then
    # Host rows ignore synthetic taps; DEBUG.md documents the physical style for them.
    axe tap --udid "${UDID}" -x "${row%% *}" -y "${row##* }" --tap-style physical >/dev/null
    sleep 1.5
    dump_tree
  fi
  local field; field="$(ui_centre textfield)"
  [[ -n "${field}" ]] || { echo "try-typing text field not found" >&2; exit 5; }
  axe touch --udid "${UDID}" -x "${field%% *}" -y "${field##* }" --down --up --delay 0.05 >/dev/null
  sleep 2
  local globe=""
  for _ in 1 2 3 4 5; do
    dump_tree
    globe="$(ui_centre globe)"
    [[ -n "${globe}" ]] && break
    sleep 1
  done
  [[ -n "${globe}" ]] || { echo "keyboard did not appear" >&2; exit 6; }
  # One command for the hold; separate down/up calls register as a swipe (DEBUG.md section 5).
  axe touch --udid "${UDID}" -x "${globe%% *}" -y "${globe##* }" --down --up --delay 1.5 >/dev/null
  sleep 1.5
  dump_tree
  # WHY: a run that cannot read the Songyan row must fail loudly; a JSON without the label
  # would look like a successful observation with an empty value.
  python3 - "${TREE}" <<'PY' || exit 12
import json,sys
tree=json.load(open(sys.argv[1]))
rows=[]
def walk(n):
    if isinstance(n,list):
        for c in n: walk(c)
        return
    if not isinstance(n,dict): return
    fr=n.get('frame') or {}
    if n.get('type')=='GenericElement' and 180<fr.get('width',0)<230 and n.get('AXLabel'):
        rows.append(n['AXLabel'])
    for c in (n.get('children') or []): walk(c)
walk(tree)
if not [r for r in rows if "松烟" in r]:
    print("globe menu open but no Songyan row in the tree",file=sys.stderr)
    raise SystemExit(1)
PY
  local shot="${SHOTS}/${index}-${tag}-globe-menu.png"
  sim io "${UDID}" screenshot "${shot}" >/dev/null
  python3 - "${LOGS}/${tag}-menu.json" "${tag}" "${shot}" "$(langs_read)" "$(locale_read)" "${TREE}" <<'PY'
import json,sys,datetime
f,tag,shot,langs,locale,path=sys.argv[1:7]
tree=json.load(open(path))
rows=[]
def walk(n):
    if isinstance(n,list):
        for c in n: walk(c)
        return
    if not isinstance(n,dict): return
    fr=n.get('frame') or {}
    # Menu cells are the only generic elements with this fixed width.
    if n.get('type')=='GenericElement' and 180<fr.get('width',0)<230 and n.get('AXLabel'):
        rows.append({"y":round(fr.get('y',0)),"label":n['AXLabel']})
    for c in (n.get('children') or []): walk(c)
walk(tree)
rows.sort(key=lambda r:r["y"])
songyan=[r for r in rows if "松烟" in r["label"]]
entry=songyan[0]["label"] if songyan else None
language=None
if entry and "," in entry:
    language=entry.rsplit(",",1)[1].strip()
json.dump({"tag":tag,"capturedAt":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "AppleLanguages":langs.split(","),"AppleLocale":locale,"screenshot":shot,
           "menuRows":rows,"songyanEntry":entry,"songyanLanguageLabel":language},
          open(f,"w"),ensure_ascii=False,indent=2)
print(json.dumps({"tag":tag,"songyanEntry":entry,"languageLabel":language,
                  "rows":[r["label"] for r in rows]},ensure_ascii=False,indent=2))
PY
  # Dismiss by tapping the text field measured in this run, so no coordinate is hardcoded.
  axe touch --udid "${UDID}" -x "${field%% *}" -y "${field##* }" --down --up --delay 0.05 >/dev/null 2>&1 || true
}

# WHY: the globe menu shows only the language name iOS assigns to the extension. A system app
# screenshot proves the preference switched system UI, not just one label.
system_shot() {
  local tag="$1" index="${2:-0}"
  sim launch "${UDID}" com.apple.Preferences >/dev/null
  sleep 2
  local ready=no
  for _ in 1 2 3 4 5 6 7 8; do
    dump_tree
    ready="$(system_ready)"
    [[ "${ready}" == "yes" ]] && break
    sleep 1
  done
  [[ "${ready}" == "yes" ]] || { echo "Settings app window never rendered" >&2; exit 11; }
  local shot="${SHOTS}/${index}-${tag}-settings-app.png"
  sim io "${UDID}" screenshot "${shot}" >/dev/null
  echo "${shot}"
}

restore() {
  local f="${LOGS}/baseline.json"
  [[ -s "${f}" ]] || { echo "no baseline to restore" >&2; exit 7; }
  local base_udid langs locale
  base_udid="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["udid"])' "${f}")"
  # WHY: a baseline from another simulator would restore a language this device never had.
  [[ "${base_udid}" == "${UDID}" ]] || { echo "baseline belongs to ${base_udid}, not ${UDID}" >&2; exit 9; }
  langs="$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))["AppleLanguages"]))' "${f}")"
  locale="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["AppleLocale"])' "${f}")"
  local -a parts; IFS=',' read -r -a parts <<<"${langs}"
  sim spawn "${UDID}" defaults write -g AppleLanguages -array "${parts[@]}"
  sim spawn "${UDID}" defaults write -g AppleLocale -string "${locale}"
  sim spawn "${UDID}" killall -u "$(id -u)" cfprefsd 2>/dev/null || true
  reboot
  local after after_locale
  after="$(langs_read)"; after_locale="$(locale_read)"
  python3 - "${LOGS}/restore.json" "${langs}" "${after}" "${locale}" "${after_locale}" <<'PY'
import json,sys,datetime
f,want,got,want_locale,got_locale=sys.argv[1:6]
verdict="restored" if (got==want and got_locale==want_locale) else "MISMATCH"
json.dump({"capturedAt":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "restoredAppleLanguages":got.split(","),"restoredAppleLocale":got_locale,
           "verdict":verdict},open(f,"w"),ensure_ascii=False,indent=2)
print(json.dumps({"wantLanguages":want,"gotLanguages":got,
                  "wantLocale":want_locale,"gotLocale":got_locale,"verdict":verdict},
                 ensure_ascii=False,indent=2))
PY
  [[ "$(langs_read)" == "${langs}" && "$(locale_read)" == "${locale}" ]] || exit 8
}

case "${MODE}" in
  --save-baseline) save_baseline ;;
  --apply) apply_lang "${1:?languages}" "${2:?locale}" "${3:?tag}" ;;
  --menu-shot) menu_shot "${1:?tag}" "${2:-0}" ;;
  --system-shot) system_shot "${1:?tag}" "${2:-0}" ;;
  --restore) restore ;;
  *) echo "unknown mode ${MODE}" >&2; exit 64 ;;
esac
