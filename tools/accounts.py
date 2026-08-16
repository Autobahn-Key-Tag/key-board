#!/usr/bin/env python3
"""
Key Board — create and manage the accounts.

    python3 tools/accounts.py

WHY THIS IS A SCRIPT AND NOT A SCREEN IN THE APP: this project has three
accounts — John, the kiosk, and the television — and they are created once.
Dispatch needs an admin dashboard because staff come and go; here, building one
would mean an admin Edge Function, an admin route, and a set of privileged
endpoints existing permanently to serve an action taken about once a year. The
attack surface would outlast the need by a wide margin.

So account management lives here instead, and the whole of it is: create one,
reset a code, switch one off. Nothing in the deployed app can do any of these.

Creating a login needs the secret key, which bypasses every rule in
db/schema.sql and must never reach the repo, the app, the tablet, or the TV. It
lives in this process for the length of one command. The script prompts for it
rather than reading a shell variable: an `export` line stays in your shell
history, and this is the one credential that must not.

Safe to stop at any point — nothing is written until every check has passed, and
a half-made account is rolled back rather than left behind.

No dependencies — standard library only.
"""

import getpass
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = ""                 # filled in by main()
SECRET = ""              # filled in by main(), never written anywhere

# Reserved TLD (RFC 2606), guaranteed never to resolve. These addresses are
# internal handles for Supabase Auth; no mail is ever sent and nobody sees them.
# Must match EMAIL_DOMAIN in supabase/functions/login/index.ts.
EMAIL_DOMAIN = "keyboard.invalid"
CODE_LENGTH = 8          # mirrors app_code_length() in db/schema.sql

# The three kinds of account, and the flags each one carries.
#
# These combinations are also enforced by the database: the display_is_read_only
# constraint on `users` refuses is_display alongside either write flag. This
# table being right is convenience; that constraint is the actual guarantee.
KINDS = {
    "admin": {
        "label": "John — creates accounts, edits the advisor list, can work the board",
        "flags": {"is_admin": True, "can_handle_keys": True, "is_display": False},
        "device": False,
    },
    "kiosk": {
        "label": "The tablet — checks keys in and out, nothing else",
        "flags": {"is_admin": False, "can_handle_keys": True, "is_display": False},
        "device": True,
    },
    "display": {
        "label": "The television — reads the board, writes nothing, ever",
        "flags": {"is_admin": False, "can_handle_keys": False, "is_display": True},
        "device": True,
    },
}


def call(path, method="GET", body=None):
    headers = {
        "apikey": SECRET,
        "Authorization": f"Bearer {SECRET}",
        "Content-Type": "application/json",
        "Prefer": "return=representation",
    }
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{URL}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw, status = r.read().decode(), r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read().decode(), e.code
    except Exception as e:
        return 0, str(e)
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, raw


def die(msg):
    print(f"\n  {msg}\n", file=sys.stderr)
    sys.exit(1)


def ask(prompt, choices=None):
    while True:
        answer = input(f"  {prompt} ").strip()
        if choices is None:
            return answer
        if answer in choices:
            return answer
        print(f"  One of: {', '.join(choices)}")


def choose_code(device: bool) -> tuple[str, bool]:
    """Return (code, was_generated).

    For a person, the code is typed twice and never printed: it is going to be
    memorised, so putting it on a terminal — and into a scrollback buffer, and
    possibly a screen recording — is exposure for nothing.

    For a device, somebody has to read it off this screen and type it into a
    tablet or a television, once, ever. Refusing to show it would just mean
    picking a memorable one instead, which is worse. So a device code is random
    by default, shown exactly once, and long odds against a guesser.
    """
    if device:
        print("\n  A random code is best here: nobody has to remember it, it gets")
        print("  typed into the device once, and it is never used again.")
        if ask("Generate one? [Y/n]", ["", "y", "Y", "n", "N"]).lower() in ("", "y"):
            # secrets, not random: this is a credential.
            return "".join(secrets.choice("0123456789") for _ in range(CODE_LENGTH)), True

    while True:
        code = getpass.getpass(f"  {CODE_LENGTH}-digit code: ").strip()
        if not re.fullmatch(rf"[0-9]{{{CODE_LENGTH}}}", code):
            print(f"  Must be exactly {CODE_LENGTH} digits.")
            continue
        if code != getpass.getpass("  Again to confirm: ").strip():
            print("  Those did not match.")
            continue
        return code, False


def code_is_taken(code) -> bool:
    """Two accounts sharing a code is two accounts that might get each other's
    session: verify_login_code returns whichever row matches first."""
    status, taken = call("/rest/v1/rpc/verify_login_code", "POST", {"p_code": code})
    if status not in (200, 204):
        die(f"Could not check whether that code is free (HTTP {status}).")
    return bool(taken)


def list_accounts():
    status, rows = call(
        "/rest/v1/users?select=id,name,is_admin,can_handle_keys,is_display,active"
        "&order=created_at.asc")
    if status != 200:
        die(f"Could not read the accounts (HTTP {status}).")
    return rows or []


def show(rows):
    if not rows:
        print("\n  No accounts yet.\n")
        return
    print("\n  Accounts:")
    for i, r in enumerate(rows, 1):
        kind = ("admin"   if r["is_admin"]
                else "display" if r["is_display"]
                else "kiosk"   if r["can_handle_keys"]
                else "no capabilities")
        state = "" if r["active"] else "  (switched off)"
        print(f"    {i}. {r['name']} — {kind}{state}")
    print()


def pick(rows, prompt):
    show(rows)
    while True:
        raw = input(f"  {prompt} (number, or blank to cancel) ").strip()
        if not raw:
            die("Nothing was changed.")
        if raw.isdigit() and 1 <= int(raw) <= len(rows):
            return rows[int(raw) - 1]
        print("  Not one of those.")


# --- the three actions ------------------------------------------------------

def create():
    print("\n  What kind of account?\n")
    for key, spec in KINDS.items():
        print(f"    {key:8} {spec['label']}")
    print()
    kind = ask("Kind:", list(KINDS))
    spec = KINDS[kind]

    existing = [r for r in list_accounts() if r["active"]]
    if kind == "display" and any(r["is_display"] for r in existing):
        print("\n  Careful: there is already an active display account.")
        print("  A second one is fine if you are adding a second screen, but if you")
        print("  are replacing a TV, reset the existing code instead — that way the")
        print("  old one stops working.")
        if ask("Create another anyway? [y/N]", ["y", "Y", "n", "N", ""]).lower() != "y":
            die("Nothing was created.")

    default = {"admin": "John", "kiosk": "Front Desk Kiosk", "display": "Key Board TV"}[kind]
    name = ask(f"Name [{default}]:") or default
    if not (1 <= len(name) <= 60):
        die("A name is required.")

    code, generated = choose_code(spec["device"])
    if code_is_taken(code):
        die("That code is already in use. Pick a different one.")

    # --- From here on something exists, so every failure has to clean up -----
    email = f"u-{secrets.token_hex(8)}@{EMAIL_DOMAIN}"
    status, auth_user = call("/auth/v1/admin/users", "POST", {
        # Random and thrown away. Nothing ever signs in with it — the login
        # function mints sessions through a single-use token, so there is no
        # replayable password stored anywhere.
        "email": email,
        "password": secrets.token_urlsafe(32),
        "email_confirm": True,
    })
    if status not in (200, 201) or not isinstance(auth_user, dict) or "id" not in auth_user:
        die(f"Could not create the login: HTTP {status} {auth_user}")
    uid = auth_user["id"]

    def rollback(why):
        call(f"/auth/v1/admin/users/{uid}", "DELETE")
        die(f"{why}\n  The half-made login was removed. Nothing was left behind.")

    status, _ = call("/rest/v1/users", "POST",
                     {"id": uid, "name": name, "active": True, **spec["flags"]})
    if status not in (200, 201):
        # The likeliest cause is display_is_read_only, and it would mean KINDS
        # above and the constraint have drifted apart. Say so rather than
        # printing a raw Postgres error at somebody setting up a television.
        rollback(f"Created the login but not the profile: HTTP {status}\n"
                 "  If that mentions display_is_read_only, the flags in this script\n"
                 "  disagree with db/schema.sql and the database was right to refuse.")

    status, _ = call("/rest/v1/rpc/set_login_code", "POST",
                     {"p_user_id": uid, "p_code": code})
    if status not in (200, 204):
        rollback(f"Created the account but could not set the code: HTTP {status}")

    print(f"\n  ✓ {name} ({kind}) can sign in now.")
    if generated:
        print(f"\n      code:  {code}\n")
        print("  Shown once. It is hashed in the database and cannot be read back,")
        print("  by anyone, including you. Type it into the device now, or reset it")
        print("  from this script later.\n")
    else:
        print("    The code is not printed. If you did not write it down, reset it")
        print("    from this script rather than guessing.\n")


def reset_code():
    row = pick(list_accounts(), "Reset whose code?")
    is_device = row["is_display"] or (row["can_handle_keys"] and not row["is_admin"])

    print(f"\n  Resetting the code for {row['name']}.")
    print("  The old code stops working the moment this succeeds. If this is the")
    print("  television or the tablet, have the device in front of you.\n")

    code, generated = choose_code(is_device)
    if code_is_taken(code):
        die("That code is already in use by another account. Pick a different one.")

    status, _ = call("/rest/v1/rpc/set_login_code", "POST",
                     {"p_user_id": row["id"], "p_code": code})
    if status not in (200, 204):
        die(f"Could not set the code (HTTP {status}). The old one still works.")

    print(f"\n  ✓ {row['name']}'s code has been changed.")
    if generated:
        print(f"\n      code:  {code}\n")
        print("  Shown once.\n")
    else:
        print()


def set_active():
    rows = list_accounts()
    row = pick(rows, "Switch which account on or off?")
    new_state = not row["active"]

    if not new_state:
        print(f"\n  Switching off {row['name']}. Their sessions stop working at the")
        print("  next request — app_is_active() is checked on every call, so a tablet")
        print("  already signed in loses access without anyone touching it.")
        if row["is_admin"] and sum(1 for r in rows if r["is_admin"] and r["active"]) == 1:
            die("That is the only active admin. Switching it off would leave nobody\n"
                "  able to manage the advisor list. Create another admin first.")

    status, _ = call(f"/rest/v1/users?id=eq.{row['id']}", "PATCH", {"active": new_state})
    if status not in (200, 204):
        die(f"Could not change that account (HTTP {status}).")

    print(f"\n  ✓ {row['name']} is now {'active' if new_state else 'switched off'}.\n")


def main():
    global URL, SECRET

    print("\nKey Board — accounts\n")

    # Accept what the dashboard actually gives you, not only the tidy form.
    #
    # Settings → API shows the Data API URL, which already has /rest/v1/ on the
    # end, and that is the thing under a copy button — so it is the likeliest
    # paste by some margin. An earlier version demanded the bare origin and
    # answered the obvious paste with "that does not look like a Supabase
    # project URL", which is both wrong and unhelpful: it did look like one.
    #
    # So take the project reference out of whatever was pasted and rebuild the
    # origin from it. The scheme is optional too.
    raw = (os.environ.get("SUPABASE_URL", "")
           or input("  Project URL (https://xxxx.supabase.co): ")).strip()
    match = re.match(r"^(?:https?://)?([a-z0-9]{20})\.supabase\.co(?:/.*)?$", raw, re.I)
    if not match:
        die("That does not look like a Supabase project URL.\n"
            f"  Expected something like https://abcdefghijklmnopqrst.supabase.co\n"
            f"  Got: {raw or '(nothing)'}")
    URL = f"https://{match.group(1).lower()}.supabase.co"

    SECRET = os.environ.get("KEYBOARD_SECRET_KEY", "") or getpass.getpass(
        "  Secret key (paste; it will not be shown): ").strip()
    if not SECRET:
        die("No key given. Find it in Supabase under Project Settings → API Keys,\n"
            "  as the secret key — older projects call it service_role.")
    if SECRET.startswith("sb_publishable_"):
        die("That is the publishable key. This needs the SECRET one, which is the\n"
            "  key that must never enter the repo.")

    status, _ = call("/rest/v1/users?select=id&limit=1")
    if status != 200:
        die(f"Could not reach the database with that key (HTTP {status}).\n"
            "  Check the key, and that db/schema.sql has been applied to THIS project.")

    show(list_accounts())
    print("  What would you like to do?\n")
    print("    create   add an account")
    print("    reset    change an account's code")
    print("    toggle   switch an account on or off")
    print()
    {"create": create, "reset": reset_code, "toggle": set_active}[
        ask("Action:", ["create", "reset", "toggle"])]()


if __name__ == "__main__":
    main()
