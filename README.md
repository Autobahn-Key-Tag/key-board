# Key Board

A television behind the cashier desk showing every customer key the cashiers are
currently holding, and a tablet beside it for adding and removing them. It replaces a
whiteboard that does the same job in dry-erase marker.

Background and reasoning: [PLAN.md](PLAN.md). This file is how to run it.

Sibling project: [Porter Dispatch](https://github.com/Autobahn-Porters/porter-app). Same
dealership, same key tags, same people — separate database and separate repo, for the
reasons in PLAN.md section 3.

## The two screens

Which screen you get is decided by **what your account can do**, not by the URL.

| Screen | Account | Does |
| --- | --- | --- |
| **The board** | `is_display` | Renders every live key. Reads only. Cannot write anything, ever. |
| **The kiosk** | `can_handle_keys` | Take a key in, give one back, fix a mistake. |

Anyone who can work the kiosk can also flip to the board and back. The television's
account cannot, because it has nowhere else to go.

## A key tag

The tag is the whole record — no customer name, no vehicle, no location. The whiteboard
held a tag number and so do we. What the tag *means* is derived in the database, by the
same rule dispatch uses:

| Tag | Reads as |
| --- | --- |
| `1A47` | Anthony — first character is the advisor |
| `TD55` | Tow-in |
| `9E1` | **Tow-in** — three characters, and length is tested before the `T` rule |
| `2B` | N/A — one or two characters is a mistyped tag, not a kind of job |
| `ZF88` | Unknown, in red — a real tag whose advisor we do not have |

`9E1` being a tow-in rather than Jovis reads wrong at a glance and is deliberate: tow-in
tags are printed as a bare number and carry no advisor character at all. Don't "fix" it.

An unmatched character is warned about, never blocked. A cashier holding a real tag must
never be stuck at the desk because the advisor list is behind.

The advisor is resolved at check-in and **stored**. Reassigning a character next month
must not rewrite what the board said today.

## Setting it up

**1. Apply the schema.** Paste [`db/schema.sql`](db/schema.sql) into the Supabase SQL
editor and run it. Safe to re-run: it recreates functions and policies without touching
data. Section 8 raises on any broken invariant, so an error at the bottom is the file
telling you something is wrong rather than a mystery.

**2. Seed the advisors.** [`db/seed-advisors.sql`](db/seed-advisors.sql). Returns the nine
advisors; every colour should be different.

**3. Check what actually landed.** [`db/verify.sql`](db/verify.sql) is read-only and
returns a row per invariant, failures first. Step 1 already checks all of it, but a raise
that did not happen is invisible and the SQL editor does not show `NOTICE` — a correct
paste and a half-finished one both read as "Success. No rows returned".

**4. Deploy the login function.** [`supabase/functions/login/index.ts`](supabase/functions/login/index.ts),
named `login`, with **Verify JWT OFF**. It is the endpoint people call before they have a
token, so requiring one is circular. Set `KEYBOARD_SECRET_KEY` in its environment (or rely
on `SUPABASE_SERVICE_ROLE_KEY`, which Supabase provides).

**5. Create the accounts.**

```bash
python3 tools/accounts.py
```

`create` → `admin` first, then `kiosk` and `display`. Device codes are generated and shown
**once**; they are hashed on arrival and cannot be read back by anyone, including you.

**6. Put the publishable key in `index.html`.** Replace
`PASTE_THE_PUBLISHABLE_KEY_HERE`. It is public by design and belongs in the repo. The app
refuses to attempt a sign-in until it is set, rather than failing confusingly.

The key that must **never** enter this repo is the secret one. It bypasses every rule in
the schema. Bots scan public GitHub for leaked keys within minutes, so if it is ever
committed the fix is to rotate it immediately, not to delete the line in a later commit.

## Running it

Push to `main`; Pages rebuilds in about a minute.

- The **television** opens the page and signs in with the display code. Landscape. It is
  expected to stay signed in indefinitely.
- The **tablet** opens the same page and signs in with the kiosk code.

There is deliberately no admin screen. Account management is `tools/accounts.py`, run from
a laptop with the secret key held in the process for one command — three accounts created
about once a year does not justify a privileged route existing permanently to serve it.

## How the security works

The app is a public website carrying a public key. Anyone can send any query they like to
this database. What stops them is entirely in [`db/schema.sql`](db/schema.sql):

1. **RLS is on for every table**, checked by section 8 at paste time.
2. **Login codes live in `user_codes` with zero policies.** Nobody can read it. Ever.
3. **No table has an insert, update, or delete policy.** Every state change goes through a
   `SECURITY DEFINER` function that checks permissions itself and writes the event log.
4. **Codes are hashed.** A forgotten code is reset, never recovered.
5. **The secret key never enters this repo.**

### The television is the exposed credential

It sits signed in, unattended, indefinitely, in a room the public can walk into. Assume
its code is known. Everything is arranged so that knowing it is worth nothing: the display
reads live key tags and the advisor list, nothing else, and it **cannot be given** a write
capability — the `display_is_read_only` constraint on `users` refuses the combination
outright rather than relying on an admin screen to hide a checkbox.

### One live key per tag

```sql
create unique index key_tags_one_live_per_tag
  on key_tags (tag) where status = 'held';
```

One line, three jobs: check-out by typing a tag is unambiguous, double check-in is
impossible, and the tag is free for reuse the instant the key goes back.

### Check-out is a conditional write

```sql
update key_tags set status = 'returned', ...
 where id = $1 and status = 'held'
```

`and status = 'held'` is the trick, the same one dispatch uses for claiming. A second
release matches zero rows and is told so, rather than overwriting when the key actually
left.

## Why it polls instead of using realtime

The board asks `board_version()` — two numbers, about sixty bytes — every two seconds, and
refetches the board only when the answer moves.

Realtime was the original design and lost on two counts. It cannot deliver a row that
leaves the caller's policy, so the display would have had to be allowed to read returned
keys purely to be told they had been returned. And a dead socket is silent, which on a
television is indistinguishable from a quiet afternoon. **A poll that fails is
unambiguous**, and the board says so on screen within twelve seconds — banner, desaturated
board, a counter that keeps climbing.

A board that has silently stopped updating is worse than a dark one, because a dark screen
sends somebody to check.

## The board never scrolls

A board you have to scroll is a list, and a list has to be read rather than glanced at. So
the type scales to fit: a binary search over one variable that drives both the font size
and the column width, snapped to a step so a single check-in does not resize the whole
wall. Verified from 20 to 60 tags.

## Previewing the layout

```
index.html?preview=44          44 invented tags, never touches the database
index.html?preview=30&stale    the degraded state, held open so it can be looked at
```

Both carry an unmissable banner. The stale flag exists because that screen is the one
nobody sees until the day it matters, and "we think it turns red" is not the same as
having watched it turn red.

## Things to know before real use

- **`app_timezone()` in `db/schema.sql`** is `America/Los_Angeles`.
- **Run it beside the whiteboard for a week.** Do not erase the board. If the two
  disagree, the whiteboard is right and there is a bug. See PLAN.md section 10 —
  divergence between the board and the hooks is the highest-consequence risk here, and a
  screen gets trusted more than a whiteboard while deserving it less.
- **The count on the television is the cheap check.** If it says 23 and there are 25 keys
  on the hooks, somebody notices.
