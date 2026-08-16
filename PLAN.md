# Key Board — Build Plan

A TV behind the cashier desk showing every customer key the cashiers are currently
holding, and a tablet beside it for adding and removing them. It replaces the
whiteboard, which does the same job in dry-erase marker.

Read this first in the new chat. It is meant to be self-contained.

Sibling project: [Porter Dispatch](https://github.com/Autobahn-Porters/porter-app).
Same dealership, same key tags, same people — but a separate database and a separate
repo, for reasons in section 3.

---

## 1. The problem

A customer drops off a car and a key. The cashier writes the key tag on a whiteboard.
When the customer collects the car, the cashier erases it. The board answers one
question: *do we have this key, and whose is it?*

The whiteboard is genuinely good at this. It is instant, it needs no login, it never
goes down, and it sits three feet from the keys. Any replacement that is slower to
write on will be abandoned, and the failure will look like people simply not using it.

What it cannot do:

- **Answer from anywhere else.** An advisor at the other end of the building has to walk
  over or phone someone.
- **Survive an erase.** A wiped or overwritten tag leaves no trace that it was ever
  there. There is no way to ask *when* a key came in or how long it sat.
- **Group by advisor** without recopying the whole board.
- **Be read at a glance when it is full.** Fifty tags in handwriting, added in arrival
  order, is a list you scan rather than a board you glance at.

The point of doing this in software is not that a whiteboard is bad at holding tags. It
is that a database can be asked questions, and a marker cannot.

## 2. The two surfaces

| Surface | Where | Does |
| --- | --- | --- |
| **The board** | TV, always on, behind the desk | Displays every key currently held. Read-only. Nobody touches it. |
| **The kiosk** | Tablet at the desk | Check a key in. Check a key out. Fix a mistake. |

There is no third screen and no phone app. If someone needs to know whether a key is in,
they look at the TV.

**Design constraint:** check-in must cost one field and no login. The whiteboard costs a
marker stroke; anything materially slower loses to the marker. This is the entire reason
the tablet is a signed-in station rather than a personal login.

## 3. Why a separate Supabase project

The obvious move is to add tables to the dispatch database — same staff, same key tags,
one advisor list to maintain. We are not doing that, for two reasons.

**The display credential is the most exposed one in either system.** The TV sits logged
in, unattended, indefinitely, in a room the public can walk into. It is the one account
guaranteed to still be signed in at 3am on a Sunday. In its own project it can reach
nothing but a list of key tags, because there is nothing else in the project to reach. In
the dispatch database it would be one policy mistake away from staff records and
request history.

**Blast radius.** `db/schema.sql` in dispatch is applied by hand in the SQL editor. A
mistake while building the key board should not be able to stop porters moving cars.

The usual cost of a separate project — a second set of staff logins to maintain — barely
applies here, because **this app has almost no users**: an admin, a kiosk, and a display.
Nobody signs in personally at all.

The real cost is the **advisor list, which now exists twice**. See section 9.

## 4. What we're building on

- **Supabase** — a new project. Hosted Postgres, plus realtime so the TV updates itself.
- **A one-page web app** on **GitHub Pages**, in a new repo. The TV opens one route, the
  tablet opens another. Same page, same deploy.
- **No server of our own**, same as dispatch.

## 5. The key tag is already a modeled thing

Dispatch derives the service advisor from the first character of the four-character key
tag, in the database. We copy that whole apparatus rather than reinventing it — the same
characters map to the same nine advisors, and a tag reads the same on both screens.

Copied verbatim from `porter-app/db/schema.sql`:

| Piece | What it does |
| --- | --- |
| `service_advisors` table, with `key_char` | The list, one character each, unique among active advisors |
| `advisor_for_code(text)` | First character → advisor, or null |
| `tag_type` generated column | Tells *tow-in* from *no advisor* from *unrecognised* |
| `advisor_palette()`, `next_free_advisor_color()`, `assign_advisor_color()` | Twelve OKLCH-spaced hues, auto-assigned, freed on deactivation |

This earns its keep immediately in two places.

**It validates typing, for free.** As the cashier types the tag, the advisor's name
appears under it. A wrong first character shows the wrong name, and an unrecognised one
shows **Unknown** in red. A four-character code is otherwise unverifiable — every typo
produces another plausible code — so this is the only check we get, and we get it
without asking anyone to confirm anything.

**It gives the board a layout.** Grouping by advisor turns an arrival-ordered list into
columns somebody can actually glance at.

As in dispatch: the advisor is **resolved at check-in and stored**, never looked up live.
Reassigning a character next month must not rewrite what the board said today. And the
advisor's **name is always rendered beside the colour** — twelve hues cannot all be told
apart by the roughly one man in twelve with red-green colour blindness, so colour is a
grouping aid and never the identifier.

### What a tag reads as

```
  3 characters            -> Tow-In.   Tow-in tags are printed as a bare number and
                                       carry no advisor character at all.
  fewer than 3            -> N/A.      One or two characters is a mistyped tag,
                                       not a kind of job.
  starts with T           -> Tow-In.
  first character matches -> that advisor.
  matches nobody          -> Unknown, in red.
```

Length is tested **before** the `T` rule, so `TE1` is a tow-in by being three characters,
and would be one anyway. The order only shows up on a three-character tag starting with
something else — `9E1` is a tow-in, not Jovis.

`porter-app/README.md` currently describes three characters as *N/A* and `TE1` as N/A;
`SECURITY-TESTS.md` records `9E1 -> none`. Both predate the generated column being
replaced, and neither matches what dispatch actually does today. **The schema is right and
the docs are stale** — worth a small correction over there, since the next person to
implement this rule will read the README. Section 12, question 1.

## 6. Data model

A row is **a key we took in**, not a tag. The same tag comes back on a different car next
month; that is a second row, and the first one stays exactly as it was.

```
key_tags
  id             uuid, primary key
  tag            text          -- as printed on the physical tag, uppercased
  tag_type       text          -- generated: 'advisor' | 'tow_in' | 'none'
  advisor_id     uuid -> service_advisors, null   -- resolved at check-in, then frozen
  status         text          -- 'held' | 'returned' | 'voided'
  checked_in_at  timestamptz
  checked_in_by  uuid -> users
  returned_at    timestamptz, null
  returned_by    uuid -> users, null
  voided_at      timestamptz, null
  voided_by      uuid -> users, null
  void_reason    text, null
```

Nothing else. No customer name, no vehicle, no location — the whiteboard holds a tag
number and so do we. Fields are cheap to add later and expensive to type fifty times a
day.

Rows are never deleted. A mistyped tag becomes `voided` with a reason, so the board
clears but the record of the mistake survives — a tag that was voided twice in a week
tells you something about the tag or the person reading it.

### One live key per tag, enforced by the database

```sql
create unique index key_tags_one_live_per_tag
  on key_tags (tag) where status = 'held';
```

This single line does three jobs:

1. Makes **check-out by typing a tag unambiguous.** Four characters always identify at
   most one live row, so there is never a "which one did you mean?" step.
2. Makes **double check-in impossible.** Two cashiers taking in the same key, or one
   cashier tapping twice, produces a unique violation on the second — which we render as
   *"That key is already on the board, checked in at 9:14."* Not an error; an answer.
3. Frees the tag the moment it is returned, because the index only covers live rows.

If it turns out two live keys genuinely can share a tag, this index is the thing that
breaks first and loudly — which is the right way to find out.

### Check-out is a conditional write

The same trick dispatch uses for claiming:

```sql
update key_tags set status = 'returned', returned_at = now(), returned_by = $2
 where id = $1 and status = 'held'
returning *;
```

`and status = 'held'` means a second release of the same key affects zero rows and gets
told so, rather than overwriting the first one's timestamp. Less likely here than two
porters claiming a car, but the correct version costs nothing.

## 7. The board (TV)

Twenty to fifty tags at the busy point, so **everything fits on one screen and nothing
ever scrolls.** A board that scrolls is a list, and a list has to be read.

- **Grouped into columns by advisor**, each column headed with the advisor's name in
  their colour. Tow-in, N/A and Unknown get their own columns at the end.
- **Oldest first within a column**, so a key that has been sitting for two days drifts to
  the top on its own, with no rule to write and nothing to configure.
- **A total count, large.** The single most useful number on the screen: if the board
  says 23 and there are 25 keys on the hooks, somebody notices. This is the only cheap
  defence against the app and reality drifting apart — see section 10.
- Type scales to the fullest the board gets. Legible across the room at fifty tags, not
  merely at twenty.

### A frozen board looks exactly like a correct one

This is the real hazard of putting a screen on a wall. If the realtime connection drops,
or the tab is suspended, or the deploy didn't reach it, the TV keeps showing a plausible
board forever and everyone keeps trusting it. **A display that has silently stopped
updating is worse than a dark one**, because a dark screen sends someone to check.

So the board proves it is alive:

- A quiet "updated 4s ago" that anyone can look at.
- If no update or heartbeat lands within a threshold, the whole board visibly degrades —
  banner, dimmed tags, an unmissable state change. Wrong beats stale-and-confident.
- It reconnects on its own, and reloads itself on the daily rollover, so a fix reaches it
  without anyone finding a keyboard for the TV.

Dispatch learned this the expensive way with service worker caching: an app on a Home
Screen ran last week's code with no symptom. Same failure, more visible mounting.

## 8. The kiosk (tablet)

Signed in as a station account for the day. No personal code, ever.

**Check in.** One field. Type the tag, see the advisor's name appear, done — Enter
commits and the field clears ready for the next one. The tag lands on the TV in under a
second. No confirmation dialog: the confirmation is that it is now on the wall.

**Check out.** The kiosk mirrors the board. Typing filters it live, and any row can be
tapped — a full tag usually narrows to one after two characters, and a damaged or
half-read tag can be found by eye instead. When exactly one row is left it is shown
large, with its advisor, and one tap releases it. **That display *is* the confirmation
step** — handing back a customer's key is the moment in this app that carries liability,
and it deserves the half second, but not a dialog.

Filtering is client-side over at most fifty rows the tablet already has. No round trip
per keystroke, and it keeps working through a flaky moment on the desk wifi.

**Fix a mistake.** Undo the last check-in for a minute afterwards, and void any live row
with a reason. A typo'd tag is otherwise immortal: it can never be checked out, because
the key that would clear it says something different. On a whiteboard a human reads the
tag and self-corrects. Here nothing does, so we build the eraser.

## 9. Two advisor lists

The advisor list now exists in both projects, and John maintains it in one place while
the other goes stale. Being honest about it up front:

- **Dispatch is the source of truth.** The key board's list is a copy, seeded with the
  same nine advisors and the same characters.
- Advisor churn is rare — a few times a year — so a documented step in the runbook
  ("added an advisor? add them in both") is proportionate.
- **The board fails safe when it drifts.** An unrecognised character shows **Unknown** in
  red rather than blocking the check-in, so a stale list costs a red label, never a key
  that can't be taken in.
- If it does become a nuisance, the fix is one-way: dispatch exposes its advisor list and
  the key board syncs from it. Worth doing when it hurts, not before.

## 10. The failure mode that matters: divergence

Everything above is easy compared to this. **The whiteboard is trusted because a human
wrote it standing next to the keys.** A screen is trusted more than that, and deserves it
less. If the board says we hold a key we returned an hour ago, someone tells a customer
their key is here when it isn't — and unlike a whiteboard, nobody suspects the screen.

Every mitigation is cheap and none is optional:

- **The count on the TV**, checkable against the hooks in two seconds by anyone walking
  past.
- **A close-of-day glance.** Keys don't stay overnight, so the board should be near empty
  at close. Anything still on it is either a real problem or a missed check-out, and
  either way somebody should see it before going home.
- **Void with a reason**, so the correction is a recorded event and not a quiet edit.
- **Run alongside the whiteboard for a full week** (Phase 4). Do not erase the board. If
  the two disagree, the whiteboard is right and we have a bug.

## 11. Security

Same standing rules as dispatch, and they are not restated here except where this app
differs: RLS on every table, no insert/update/delete policies, every state change through
a `SECURITY DEFINER` function, codes hashed and kept in their own policy-less table, the
service key never in the repo.

Three things are specific to this app.

**The display account is read-only and reaches one thing.** It can select key tags and
the advisor list. Not users, not the event log, not codes. Its session does not expire at
3am, because a TV nobody logs into is the entire point — which is exactly why the
capability has to be this narrow. Treat the code as public: it will be typed on a screen
in a shared room and left signed in forever. It should be worth nothing to whoever reads
it over someone's shoulder, and revoking it should cost one checkbox.

It is also forbidden from *holding* a write capability, by a check constraint on `users`
rather than by the admin screen hiding a box. A display account that can write is a public
terminal with a keyboard attached to the board, and that is the kind of thing somebody
ticks once while debugging and never unticks.

> **Narrowed to live rows only, then widened back — deliberately.** The obvious policy is
> `status = 'held'`, so the TV can read the board and no history at all. It does not work.
> Realtime evaluates the policy against the *new* row, so the instant a key is checked out
> the row stops matching and **the update is never delivered** — the TV, having heard
> nothing, leaves the tag up indefinitely. The tighter rule produces exactly the failure
> section 7 exists to prevent: a board that is confidently wrong with nothing on screen to
> say so. So the display reads returned and voided rows too. Yesterday's returned tags are
> strictly less sensitive than today's held ones, which it must read anyway; what the
> widening buys is tags leaving the board the moment the key does.

**The kiosk account can check keys in and out and nothing else.** It cannot manage users
or advisors. A tablet on a desk is the most stealable device in the building; deactivating
its account must be a complete answer.

**There is no admin screen, and that is a security decision as much as a scope one.**
Account management lives in `tools/accounts.py`, run from a laptop with the secret key
held in the process for one command. Dispatch needs a dashboard because staff come and
go; here there are three accounts, created once. Building the equivalent would mean an
admin Edge Function and a privileged route existing permanently to serve an action taken
roughly once a year — surface that long outlives the need. Nothing in the deployed app
can create an account, reset a code, or switch one off.

**Anonymous reaches nothing at all.** No world-readable view, no "safe" subset. The
board's data is customer information — a list of which cars are in the shop right now —
and the anon key ships inside a public web page.

### Tested, not assumed

Same gate as dispatch: a Python suite whose exit code 0 is a release gate, with results
written into `SECURITY-TESTS.md` when run. Before Phase 1 is called done:

- [ ] RLS confirmed on every table.
- [ ] Anonymous read of every table returns 401, and a nonexistent table returns 404 —
      compared directly, so "everything is refused" can't be "nothing exists".
- [ ] The **display account cannot write anything**: check in, check out, void — refused
      by the database, verified by reading the row back afterwards, not by status code.
- [ ] The display account cannot read `users`, `user_codes`, or `key_tag_events`.
- [ ] A display account **cannot be given** a write capability — the check constraint
      refuses the update, rather than the admin screen declining to offer it.
- [ ] The kiosk account cannot create users or edit advisors.
- [ ] Checking in a tag already live fails, and the existing row is unchanged.
- [ ] Releasing an already-returned key affects zero rows and does not move
      `returned_at`.

## 12. Open questions before Phase 0

1. **Dispatch's release gate is currently red.** Settled for this project — a
   three-character tag is a tow-in, per section 5 — but `tests/security_test.py:314-315`
   still assert `9E1` and `TE1` derive `none`, and the deployed schema returns `tow_in`
   for both. Two checks fail, so exit code 0 is unavailable, so the gate that is supposed
   to block a release on a security regression is instead permanently failing for a
   documentation reason. `README.md` and `SECURITY-TESTS.md` describe the old rule too.
   A small PR against that repo. Not a blocker here, but it should not sit.
2. **Repo and app name.** "Key Board" is a placeholder that happens to pun; anything else
   is fine.
3. **The TV.** Size, landscape or portrait, how far the furthest reader stands, and how
   it is driven — a stick PC, a smart TV browser, an iPad? That last one decides how
   forgiving we can be about background tab suspension.
4. **Can customers see the screen?** Tag numbers are meaningless to a stranger, so the
   board is safe to expose as designed. It is worth confirming rather than assuming.
5. **One kiosk or more?** The design already tolerates several; it changes only how much
   the conditional writes actually matter.
6. **What happens to a key at close of business?** "Keys don't stay overnight" is the
   rule — how often is it broken in practice, and by what?
7. **Are there keys with no tag**, or a handwritten one? The whiteboard tolerates
   anything a marker can write; a four-character field does not.

## 13. Phases

### Phase 0 — Setup
Supabase project, schema, RLS, the three accounts (admin, kiosk, display), repo and Pages.
**Done when:** the TV loads an empty board and the security suite's anonymous phase passes.

### Phase 1 — Check-in and the board
The kiosk's one field; the TV rendering live, grouped by advisor, with the count.
**Done when:** a tag typed on the tablet is on the TV in under a second, a duplicate is
refused with a useful message, and every box in section 11 has been run and recorded.

### Phase 2 — Check-out and correction
Type-ahead and tap, the confirm-by-showing release, undo, void with a reason.
**Done when:** a cashier can clear a key from the board faster than erasing it, with the
board full.

### Phase 3 — Trust the wall
Liveness indicator, visible degradation, self-reconnect, daily reload. Close-of-day view.
**Done when:** pulling the network makes the TV *say* it is stale within the threshold.

### Phase 4 — Pilot
Run beside the whiteboard for a week. Do not erase it. Fix what the cashiers actually
complain about, then write the runbook.
**Done when:** the cashiers stop writing on the whiteboard because the TV is the thing
they check.

## 14. Costs

| Item | Cost |
| --- | --- |
| Supabase free tier | $0 — fifty rows a day is nothing |
| Supabase Pro | $25/mo if backups are wanted; a second project is a second bill |
| GitHub Pages | $0 |
| The TV and tablet | Hardware, not software |

## 15. Known risks

- **Divergence between the board and the hooks.** Section 10. The highest-consequence
  risk in the project and the reason for the count and the pilot week.
- **A silently stale TV.** Section 7. Mitigated by making liveness visible, because the
  failure is invisible by nature.
- **Check-in friction.** If it is slower than a marker it will be skipped, and a partly
  used board is worse than no board — it looks authoritative and isn't. Mitigated by the
  station login and the single field, and measured during the pilot rather than assumed.
- **Two advisor lists.** Section 9. Fails safe, but it will drift.
- **The display credential.** Signed in forever in a semi-public room. Mitigated by
  giving it nothing worth having.
- **Single maintainer.** Same as dispatch: keep the runbook current so a competent
  developer could pick it up cold.
