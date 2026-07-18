#!/usr/bin/env bats
# user-gui.bats — the account setup screen (SPEC §4.6, issue #8).
#
# The password is the one thing wootc cannot migrate: Windows stores an NTLM
# hash, Linux a PAM/shadow crypt hash, and copying credential material would
# breach the "never migrate secrets" rule. So this screen pre-fills everything
# non-secret and asks for exactly one new thing.
#
# The tests that matter most here are the negative ones. A password leaking into
# a world-readable file in the user's home, or into argv (readable by any
# process via /proc/<pid>/cmdline), is a real vulnerability on a machine this
# tool is meant to make safe — and it is exactly the kind of regression a
# refactor introduces silently.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GUI="$REPO_ROOT/payload/migration/wootc-user-gui"
    export PATH="$REPO_ROOT/payload/migration:$PATH"
    export WOOTC_ACCOUNT="$BATS_TEST_TMPDIR/account.json"
}

py() { python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_loader('ug', None)
import types
ug = types.ModuleType('ug')
exec(open('$GUI').read().split('def build_gui')[0], ug.__dict__)
$1
"; }

@test "self-test passes" {
    run python3 "$GUI" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-test OK"* ]]
}

# ── pre-fill ────────────────────────────────────────────────────────────────

@test "identity fields are pre-filled from the scan" {
    run py "
i = {'username':'jim','fullName':'Jim Reilly','email':'jim@example.com'}
p = ug.AccountEngine.prefill(i)
assert p['username']=='jim' and p['fullName']=='Jim Reilly' and p['email']=='jim@example.com'
print('ok')"
    [ "$status" -eq 0 ]
}

@test "prefill never carries a password field through" {
    run py "
p = ug.AccountEngine.prefill({'username':'jim','password':{'migratable':False}})
assert 'password' not in p, p
print('ok')"
    [ "$status" -eq 0 ]
}

@test "the password explanation is never blank" {
    # A mandatory field with no reason reads as an obstacle, not a safeguard.
    run py "assert ug.AccountEngine.password_note({}).strip(); print('ok')"
    [ "$status" -eq 0 ]
}

# ── validation ──────────────────────────────────────────────────────────────

@test "valid usernames are accepted, invalid ones explained" {
    run py "
E = ug.AccountEngine
assert E.validate_username('jim') is None
assert E.validate_username('jim-2_x') is None
assert E.validate_username('Jim') is not None
assert E.validate_username('9jim') is not None
assert E.validate_username('') is not None
assert E.validate_username('a'*33) is not None
print('ok')"
    [ "$status" -eq 0 ]
}

@test "reserved system usernames are refused" {
    run py "
E = ug.AccountEngine
for n in ('root','daemon','nobody'):
    assert E.validate_username(n) is not None, n
print('ok')"
    [ "$status" -eq 0 ]
}

@test "passwords must meet the length floor and match their confirmation" {
    run py "
E = ug.AccountEngine
assert E.validate_password('hunter2hunter2','hunter2hunter2') is None
assert E.validate_password('short','short') is not None
assert E.validate_password('hunter2hunter2','different') is not None
assert E.validate_password('','') is not None
print('ok')"
    [ "$status" -eq 0 ]
}

@test "validate reports every problem at once, not one at a time" {
    # Fixing one error only to be shown the next is a poor experience for the
    # non-technical user this screen exists for.
    run py "
probs = ug.AccountEngine.validate({'username':'Jim','password':'x','confirm':'y'})
assert len(probs) >= 2, probs
print('ok')"
    [ "$status" -eq 0 ]
}

# ── secret handling (the load-bearing tests) ────────────────────────────────

@test "the password NEVER reaches the saved account file" {
    run py "
import json
form = {'username':'jim','fullName':'Jim','password':'hunter2hunter2','confirm':'hunter2hunter2'}
rec = ug.AccountEngine.save_identity(form, path='$WOOTC_ACCOUNT')
blob = open('$WOOTC_ACCOUNT').read()
assert 'hunter2hunter2' not in blob, blob
assert rec['passwordSet'] is True
print('ok')"
    [ "$status" -eq 0 ]
    # belt and braces: assert against the real file from the shell too
    run grep -c "hunter2hunter2" "$WOOTC_ACCOUNT"
    [ "$output" -eq 0 ]
}

@test "a future field added to the form cannot leak into the saved record" {
    # identity_record rebuilds field by field rather than copy-then-delete,
    # so unknown keys are dropped rather than silently persisted.
    run py "
import json
rec = ug.AccountEngine.identity_record({'username':'jim','secretToken':'abc123'})
assert 'secretToken' not in json.dumps(rec), rec
print('ok')"
    [ "$status" -eq 0 ]
}

@test "the password goes to chpasswd on stdin, never in argv" {
    # argv is world-readable through /proc/<pid>/cmdline.
    run py "
seen = {}
def fake(argv, input=None, capture_output=False, text=False):
    seen['argv'] = argv; seen['input'] = input
    class R: returncode = 0; stderr = ''
    return R()
ug.AccountEngine.set_password('jim','hunter2hunter2',runner=fake)
assert seen['argv'] == ['chpasswd'], seen['argv']
assert 'hunter2hunter2' not in ' '.join(seen['argv'])
assert seen['input'] == 'jim:hunter2hunter2\n'
print('ok')"
    [ "$status" -eq 0 ]
}

@test "a chpasswd failure is surfaced, not silently swallowed" {
    # Silently continuing would leave an account the user cannot log into.
    run py "
def fake(argv, input=None, capture_output=False, text=False):
    class R: returncode = 1; stderr = 'authtok failure'
    return R()
try:
    ug.AccountEngine.set_password('jim','hunter2hunter2',runner=fake)
except RuntimeError as e:
    assert 'authtok' in str(e); print('ok')
else:
    raise AssertionError('failure was swallowed')"
    [ "$status" -eq 0 ]
}

@test "set_password refuses empty credentials" {
    run py "
try:
    ug.AccountEngine.set_password('', 'pw')
except ValueError: pass
else: raise AssertionError('accepted empty username')
print('ok')"
    [ "$status" -eq 0 ]
}
