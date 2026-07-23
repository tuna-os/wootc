#!/usr/bin/env python3
"""dogtail-suite.py — drive the REAL GTK4/libadwaita wootc GUIs through
AT-SPI (accessibility bus), the Linux counterpart of the Windows CDP leg.

Unlike the screenshot capture (capture-linux-guis.sh, passive) this clicks
switches and buttons and asserts the resulting on-disk state, proving the
whole chain: a11y tree exposure -> widget behavior -> engine write-out.

Exit codes: 0 pass, 1 failures, 77 SKIP. Skip semantics matter: not every
image ships dogtail (or an a11y bus at all) — an in-guest run on such an
image must report SKIP, never a false FAIL. The containerized wrapper
(run-dogtail.sh) always provides both.

Env: WOOTC_GUI_DIR (default /scripts) — dir with the wootc-* GUIs;
     WOOTC_HOST — fixture Windows volume for the migration chooser.
"""
import json
import os
import subprocess
import sys
import time


def skip(msg):
    print(f"[SKIP] {msg}")
    sys.exit(77)


try:
    from dogtail import tree  # noqa: E402
    from dogtail.config import config
except ImportError:
    skip("dogtail is not available on this image")

if not os.environ.get("DISPLAY"):
    skip("no DISPLAY — dogtail needs an X session (Xvfb is fine)")

config.searchCutoffCount = 30
config.actionDelay = 0.2
config.logDebugToFile = False

SCRIPTS = os.environ.get("WOOTC_GUI_DIR", "/scripts")
HOSTFIX = os.environ.get("WOOTC_HOST", "/fixture/host")

failures = []


def check(cond, msg):
    print(("[PASS] " if cond else "[FAIL] ") + msg)
    if not cond:
        failures.append(msg)
    return bool(cond)


def wait_app(name, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            for a in tree.root.applications():
                if name in (a.name or ""):
                    return a
        except Exception:
            pass
        time.sleep(0.5)
    raise AssertionError(f"{name} never appeared on the AT-SPI bus")


def wait_file(path, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.3)
    return False


# GTK4's AT-SPI role mapping: GtkSwitch -> "check box", GtkButton ->
# "button" (older toolkits say "switch"/"toggle button"/"push button";
# accept both generations so the suite runs on any image that has dogtail).
def find_switches(app):
    return app.findChildren(
        lambda n: n.roleName in ("check box", "switch", "toggle button"),
        showingOnly=True)


def find_button(app, label):
    hits = app.findChildren(
        lambda n: n.roleName in ("button", "push button") and n.name == label,
        showingOnly=True)
    if not hits:
        raise AssertionError(f'no button labeled "{label}"')
    return hits[0]


def activate(node):
    """Trigger a widget through its AT-SPI action, not a synthesized mouse
    click — actions work regardless of scroll position or window stacking
    (a mouse click on a button scrolled out of the viewport lands on
    whatever is at those coordinates instead)."""
    try:
        for name in ("click", "press", "activate", "toggle"):
            if name in (node.actions or {}):
                node.doActionNamed(name)
                return
    except Exception:
        pass
    node.click()


def run_gui(script, env):
    e = dict(os.environ)
    e.update(env)
    return subprocess.Popen(["python3", os.path.join(SCRIPTS, script)],
                            env=e, stdout=subprocess.DEVNULL,
                            stderr=subprocess.STDOUT)


# ── 1. Migration chooser: toggle a category off, apply, assert selection ────
sel_path = "/tmp/dogtail-selection.json"
if os.path.exists(sel_path):
    os.unlink(sel_path)
proc = run_gui("wootc-manifest-gui", {
    "WOOTC_MANIFEST_BIN": os.path.join(SCRIPTS, "wootc-manifest"),
    "WOOTC_HOST": HOSTFIX,
    "WOOTC_SELECTION": sel_path,
})
try:
    app = wait_app("wootc-manifest-gui")
    check(True, "migration chooser exposes an AT-SPI tree")

    switches = find_switches(app)
    check(len(switches) > 0, f"chooser shows toggles ({len(switches)} found)")
    activate(switches[0])
    time.sleep(0.5)

    activate(find_button(app, "Bring it over"))
    if check(wait_file(sel_path), "apply wrote the selection file"):
        with open(sel_path) as fh:
            sel = json.load(fh)["selection"]
        offs = [c for u in sel.values() for c in u.values() if not c["on"]]
        check(len(offs) == 1,
              f"the clicked switch turned exactly one category off (got {len(offs)})")
except Exception as e:
    check(False, f"migration chooser scenario aborted: {e}")
finally:
    proc.kill()

# ── 2. Account setup: type a password, continue, assert no plaintext ────────
acct_path = "/tmp/dogtail-account.json"
if os.path.exists(acct_path):
    os.unlink(acct_path)
identity = "/tmp/dogtail-identity"
with open(identity + ".json", "w") as fh:
    json.dump({"winUser": "Alex", "username": "alex", "fullName": "Alex Morgan",
               "email": "alex@example.com", "avatar": None, "locale": "en_GB",
               "keyboardLayout": None, "timezone": None,
               "password": {"migratable": False, "note": "Set a new password."}},
              fh)
with open(identity, "w") as fh:
    fh.write(f"#!/bin/sh\ncat {identity}.json\n")
os.chmod(identity, 0o755)

proc = run_gui("wootc-user-gui", {
    "WOOTC_IDENTITY_BIN": identity,
    "WOOTC_ACCOUNT": acct_path,
})
try:
    app = wait_app("wootc-user-gui")
    check(True, "account setup exposes an AT-SPI tree")

    # Adw.PasswordEntryRow exposes as role "text" named after its title
    # (plain GtkPasswordEntry would say "password text" — accept both).
    pw_fields = app.findChildren(
        lambda n: (n.roleName in ("text", "password text")
                   and "assword" in (n.name or "")),
        showingOnly=True)
    check(len(pw_fields) >= 2, f"two password fields present ({len(pw_fields)})")
    for f in pw_fields[:2]:
        try:
            f.text = "hunter2secret"          # EditableText, focus-independent
        except Exception:
            f.click()
            f.typeText("hunter2secret")
        time.sleep(0.3)

    activate(find_button(app, "Continue"))
    if check(wait_file(acct_path), "continue wrote the account file"):
        raw = open(acct_path).read()
        check("alex" in raw, "account file carries the migrated username")
        check("hunter2secret" not in raw,
              "the typed password is not stored in plaintext")
except Exception as e:
    check(False, f"account setup scenario aborted: {e}")
finally:
    proc.kill()

print(f"\nRESULT: {'FAIL' if failures else 'PASS'} "
      f"({len(failures)} failure(s))")
sys.exit(1 if failures else 0)
