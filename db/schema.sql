-- ============================================================================
-- Key Board — database schema, security rules, and operations
-- ============================================================================
--
-- Run this once, whole, in the Supabase SQL editor of the KEY BOARD project.
-- Not the dispatch project — see PLAN.md section 3 for why these are separate.
--
-- Re-running is safe: it drops and recreates the functions and policies and
-- leaves table data alone. Dropping the tables themselves is deliberate manual
-- work.
--
-- Read the file top to bottom. It is ordered:
--   1. Extensions
--   2. Configuration you may want to change
--   3. Tables
--   4. Permission helpers
--   5. Row Level Security policies
--   6. Operations (every write goes through one of these)
--   7. Grants
--   8. Self-check
--
-- THE ONE THING TO UNDERSTAND: the app is a public website carrying a public
-- key. Anyone can send any query they like to this database. The policies in
-- section 5 and the checks in section 6 are the only thing that stops them.
-- Nothing in the user interface is a security control.
--
-- AND THE ONE THING SPECIFIC TO THIS APP: a television in a room the public can
-- walk into is signed into this database, unattended, forever. Assume its code
-- is known. Everything below is arranged so that knowing it is worth nothing.
-- ============================================================================


-- ============================================================================
-- 1. Extensions
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;


-- ============================================================================
-- 2. Configuration
-- ============================================================================

-- The dealership's local timezone. Decides when "today" started, which is what
-- the close-of-day view and the board's nightly reload hang off.
-- CHANGE THIS if the dealership is not in Pacific time.
create or replace function public.app_timezone()
returns text language sql immutable as $$ select 'America/Los_Angeles' $$;

-- The daily boundary, in local time. 3 = 3am.
create or replace function public.app_day_boundary_hour()
returns int language sql immutable as $$ select 3 $$;

-- How many digits a login code has. Enforced in set_login_code() below, so this
-- is the only place the length is written down. Same reasoning as dispatch: an
-- attacker hunts any valid code, not one person's.
--
-- This project has three accounts rather than thirty, so the odds are far worse
-- for a guesser than they are over there. The length matches dispatch anyway,
-- because a cashier who has to remember two different code lengths will write
-- one of them down.
create or replace function public.app_code_length()
returns int language sql immutable as $$ select 8 $$;

-- The most recent 3am, as an absolute time. Everything "today" happened after
-- this instant.
create or replace function public.app_day_start()
returns timestamptz
language sql stable
set search_path = ''
as $$
  select case
           when now() at time zone public.app_timezone() >= boundary then boundary
           else boundary - interval '1 day'
         end at time zone public.app_timezone()
  from (
    select date_trunc('day', now() at time zone public.app_timezone())
             + make_interval(hours => public.app_day_boundary_hour()) as boundary
  ) t;
$$;


-- ============================================================================
-- 3. Tables
-- ============================================================================

-- ---------------------------------------------------------------------------
-- users — one row per account, mirroring an auth.users row of the same id.
--
-- There are three: John, the kiosk, and the display. Nobody signs in
-- personally, so this table is small and stays small.
--
-- Unlike dispatch, it is NOT world-readable to signed-in callers. Over there
-- every user needs every name ("claimed by Marcus T.", history filtered by
-- porter). Here nothing in the interface names a person, so nobody needs to
-- read anybody else's row, so nobody may. See section 5.
-- ---------------------------------------------------------------------------
create table if not exists public.users (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text        not null check (length(trim(name)) between 1 and 60),

  -- May check keys in, out, and void a mistake. This is the kiosk.
  can_handle_keys boolean not null default false,

  -- THE TELEVISION. A read-only account whose session is not expected to end.
  --
  -- Treated throughout as a hostile-adjacent credential: it is typed once onto
  -- a screen in a shared room and then left signed in indefinitely, so it is
  -- the one account most likely to be read over somebody's shoulder or found
  -- still logged in on a device that walked off. It can see the board and
  -- nothing else, and it can write nothing at all.
  is_display      boolean not null default false,

  is_admin        boolean not null default false,

  -- Deactivate, never delete, so a returned key keeps the account that returned
  -- it. Deactivating the kiosk or the display is also the whole answer to a
  -- stolen tablet or television — one checkbox, effective immediately.
  active     boolean     not null default true,
  created_at timestamptz not null default now(),

  -- The dangerous combination made unrepresentable rather than merely unlikely.
  --
  -- A display account that could also write is a public terminal with a keyboard
  -- attached to the board. This is the kind of thing that gets ticked once by
  -- somebody debugging and never unticked, so the database refuses it outright
  -- instead of relying on the admin screen to hide the checkbox.
  constraint display_is_read_only
    check (not (is_display and (can_handle_keys or is_admin)))
);

-- ---------------------------------------------------------------------------
-- user_codes — the hashed login codes. Split out from users precisely so that
-- users could be readable while this table is readable by nobody.
--
-- RLS is enabled below with ZERO policies: every request through the public key
-- returns nothing, forever. Only the login function reaches it.
--
-- Codes are hashed, so a forgotten code is reset, never recovered.
-- ---------------------------------------------------------------------------
create table if not exists public.user_codes (
  user_id    uuid primary key references public.users(id) on delete cascade,
  code_hash  text        not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- login_attempts — what the login function counts to decide it is being
-- attacked. Zero policies; only the login function, running as service_role,
-- ever touches it.
--
-- Column names match dispatch exactly so the login function transfers without
-- edits. Two different names for the same field across two projects is the kind
-- of difference that costs an afternoon.
-- ---------------------------------------------------------------------------
create table if not exists public.login_attempts (
  id  bigserial primary key,
  ip  text,

  -- A one-way fingerprint of the submitted code, never the code. Attempts have
  -- to be countable per code, and this table leaking must not hand anybody a
  -- working credential. Note it fingerprints what was TYPED, including codes
  -- that match nobody — so this is also a list of wrong guesses, which is
  -- another reason it is readable by nobody.
  code_fingerprint text,

  succeeded boolean not null,
  user_id   uuid references public.users(id) on delete set null,
  at        timestamptz not null default now()
);

-- The three brakes count failures within a window, by code, by address, and in
-- total. Small table, but these are the queries standing between the login
-- endpoint and someone working through the code space.
create index if not exists login_attempts_at_idx   on public.login_attempts (at desc);
create index if not exists login_attempts_code_idx on public.login_attempts (code_fingerprint, at desc);
create index if not exists login_attempts_ip_idx   on public.login_attempts (ip, at desc);

-- ---------------------------------------------------------------------------
-- service_advisors — a managed list, not app users. They never log in.
--
-- A COPY of the dispatch list, not a link to it. Dispatch is the source of
-- truth; PLAN.md section 9 says so out loud and explains why the duplication is
-- tolerable — an advisor added here late costs a red "Unknown" label, never a
-- key that cannot be taken in.
--
-- Columns and constraints are identical to dispatch so the seed and the palette
-- functions transfer unchanged.
-- ---------------------------------------------------------------------------
create table if not exists public.service_advisors (
  id         uuid primary key default gen_random_uuid(),
  name       text        not null check (length(trim(name)) between 1 and 60),

  -- The first character of a key tag. This is what identifies the advisor —
  -- nobody picks one from a list, it is read off the tag in the cashier's hand.
  -- One character, unique among ACTIVE advisors (index below).
  key_char   text        check (key_char is null or key_char ~ '^[0-9A-Z]$'),

  -- Hex colour. Always displayed alongside the advisor's name, never as the
  -- only signal — roughly 1 in 12 men cannot reliably tell some of these apart.
  color      text        not null check (color ~ '^#[0-9a-fA-F]{6}$'),
  active     boolean     not null default true,
  sort_order int         not null default 0,
  created_at timestamptz not null default now()
);

-- Unique among active advisors only, so retiring somebody frees their character
-- for reuse with nothing to unbind by hand.
create unique index if not exists service_advisors_key_char_idx
  on public.service_advisors (key_char) where active and key_char is not null;

-- ---------------------------------------------------------------------------
-- key_tags — the board itself.
--
-- A row is A KEY WE TOOK IN, not a tag. The same tag comes back on a different
-- car next month; that is a second row, and the first one stays exactly as it
-- was. Nothing here is ever updated in place except its status, and nothing is
-- ever deleted.
--
-- There is no insert, update or delete policy on this table for anyone. Every
-- state change goes through section 6.
-- ---------------------------------------------------------------------------
create table if not exists public.key_tags (
  id  uuid primary key default gen_random_uuid(),

  -- As printed on the physical tag. Uppercased by check_in_key(), which is the
  -- only path that writes it — hence no upper() in the generated column below.
  --
  -- The length is not constrained to 4. A one or two character tag is almost
  -- certainly a typo, but a cashier holding a real tag we did not anticipate
  -- should not be stuck at the desk arguing with a form. It is taken in, it
  -- reads as N/A, and the cashier can void it. Same principle as an unmatched
  -- advisor character: warn, never block.
  tag text not null check (tag ~ '^[0-9A-Z]{1,12}$'),

  -- What the tag says about who owns the car, independent of whether an advisor
  -- was matched. Tells "towed in" from "no advisor" from "matches nobody we
  -- know" — three things that would otherwise all look like a null advisor.
  --
  -- Copied from dispatch, INCLUDING the order of the tests. Length is checked
  -- FIRST, so a three-character tag is a tow-in whatever it starts with: 9E1 is
  -- a tow-in, not Jovis. Tow-in tags are printed as a bare number and carry no
  -- advisor character at all, so there is nothing in them to derive. This reads
  -- wrong at a glance and is deliberate; there is a test pinning it.
  tag_type text generated always as (
    case when length(trim(tag)) = 3    then 'tow_in'
         when length(trim(tag)) < 3    then 'none'
         when left(trim(tag), 1) = 'T' then 'tow_in'
         else                               'advisor' end
  ) stored,

  -- Resolved at check-in and then frozen. NOT looked up live: reassigning a key
  -- character next month must not rewrite what the board said today.
  --
  -- Null is three different situations, told apart by tag_type above: a tow-in,
  -- a tag too short to carry a character, or a character matching no active
  -- advisor. The last renders as "Unknown" in red.
  advisor_id uuid references public.service_advisors(id),

  status text not null default 'held'
         check (status in ('held', 'returned', 'voided')),

  checked_in_at timestamptz not null default now(),
  checked_in_by uuid        not null references public.users(id),

  returned_at   timestamptz,
  returned_by   uuid references public.users(id),

  -- Voided is not deleted. A tag voided twice in a week says something about
  -- the tag, or about whoever is reading it, and that is worth keeping.
  voided_at     timestamptz,
  voided_by     uuid references public.users(id),
  void_reason   text,

  -- Guard rails so a bug cannot leave a row in a nonsensical shape.
  constraint returned_has_a_return
    check (status <> 'returned' or (returned_at is not null and returned_by is not null)),
  constraint voided_has_a_void
    check (status <> 'voided'   or (voided_at   is not null and voided_by   is not null))
);

-- ---------------------------------------------------------------------------
-- ONE LIVE KEY PER TAG.
--
-- This one line does three jobs, which is why it is an index and not a check in
-- application code:
--
--   1. Check-out by typing a tag is unambiguous. Four characters identify at
--      most one live row, so there is never a "which one did you mean?" step at
--      the moment somebody is waiting for their key.
--   2. Double check-in is impossible. Two cashiers taking in the same key, or
--      one cashier tapping twice, gets a unique violation on the second —
--      which check_in_key() turns into "already on the board, checked in at
--      9:14". An answer, not an error.
--   3. The tag is free again the instant the key goes back, because the index
--      covers live rows only. That is what makes tag reuse work.
--
-- If it turns out two live keys can genuinely share a tag, this is what breaks
-- first and loudly. That is the right way to find out.
-- ---------------------------------------------------------------------------
create unique index if not exists key_tags_one_live_per_tag
  on public.key_tags (tag) where status = 'held';

-- The board query: every live key, oldest first. The hottest query in the app
-- and the only one the television ever runs.
create index if not exists key_tags_held_idx
  on public.key_tags (checked_in_at) where status = 'held';

create index if not exists key_tags_checked_in_idx
  on public.key_tags (checked_in_at desc);

-- Deliberately NOT published to realtime, and no `replica identity full`. The
-- television polls board_version() instead; see the reasoning where that
-- function is defined in section 6.

-- ---------------------------------------------------------------------------
-- key_tag_events — the audit log. Append-only, by way of having no write policy.
--
-- The kiosk is a station account, so this records "Front Desk Kiosk" rather than
-- which cashier. That was the deliberate trade for a check-in that costs one
-- field and no login (PLAN.md section 2). What it still answers, and what the
-- whiteboard never could: when did this key arrive, when did it go, and how
-- many times has this tag been voided.
-- ---------------------------------------------------------------------------
create table if not exists public.key_tag_events (
  id         bigserial primary key,
  key_tag_id uuid not null references public.key_tags(id) on delete cascade,
  event      text not null check (event in ('checked_in', 'returned', 'voided')),
  actor_id   uuid references public.users(id),
  detail     text,
  at         timestamptz not null default now()
);

create index if not exists key_tag_events_tag_idx
  on public.key_tag_events (key_tag_id, at desc);


-- ============================================================================
-- 4. Permission helpers
--
-- Every one is SECURITY DEFINER, which means it runs with the privileges of the
-- owner and so is not itself subject to RLS. That is required, not incidental:
-- a policy on `users` that queried `users` normally would recurse forever.
--
-- `set search_path = ''` and fully-qualified names throughout. Without it a
-- caller can point search_path at a schema of their own and substitute their
-- own `users` table — a real and well-documented privilege escalation.
-- ============================================================================

create or replace function public.app_is_active()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.users where id = auth.uid() and active);
$$;

-- May check keys in and out. The kiosk, and John.
create or replace function public.app_can_handle_keys()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (can_handle_keys or is_admin)
                   from public.users where id = auth.uid() and active), false);
$$;

-- Is this the television?
--
-- Used to SUBTRACT, never to grant: everywhere it appears it is narrowing what
-- the caller can see. A bug that made this return false for the display would
-- widen the board's reach, so the operations in section 6 do not rely on it —
-- they check app_can_handle_keys(), which the display fails on its own merits
-- because the constraint on users forbids it holding that flag.
create or replace function public.app_is_display()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select is_display
                   from public.users where id = auth.uid() and active), false);
$$;

create or replace function public.app_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin
                   from public.users where id = auth.uid() and active), false);
$$;


-- ============================================================================
-- 5. Row Level Security
--
-- Enabled on every table without exception. A single table missed here is
-- readable in full by anyone on the internet holding the publishable key, with
-- no login and no trace. Section 8 checks that none was missed.
-- ============================================================================

alter table public.users            enable row level security;
alter table public.user_codes       enable row level security;
alter table public.login_attempts   enable row level security;
alter table public.service_advisors enable row level security;
alter table public.key_tags         enable row level security;
alter table public.key_tag_events   enable row level security;

-- Note on FORCE ROW LEVEL SECURITY: deliberately NOT used on user_codes or
-- login_attempts. FORCE applies policies to the table owner too, and the login
-- function is SECURITY DEFINER — it runs as the owner. Those two tables have
-- zero policies on purpose, so forcing RLS would make the login path read
-- nothing and every login would fail. Ordinary callers are not the owner, so
-- they still get nothing, which is the point.

drop policy if exists users_select        on public.users;
drop policy if exists users_admin_update  on public.users;
drop policy if exists advisors_select     on public.service_advisors;
drop policy if exists advisors_admin_all  on public.service_advisors;
drop policy if exists key_tags_select     on public.key_tags;
drop policy if exists key_events_select   on public.key_tag_events;

-- --- users -----------------------------------------------------------------
-- Your own row, or everything if you are John. Nobody can enumerate the
-- accounts.
--
-- Dispatch is deliberately more open than this: over there every signed-in user
-- reads every name because the queue and the history are full of them. Here no
-- screen names a person, so the same openness would be a list of accounts handed
-- to a television for no reason at all.
create policy users_select on public.users
  for select to authenticated
  using (public.app_is_active() and (id = auth.uid() or public.app_is_admin()));

-- Only John changes flags or deactivates an account. No INSERT policy: creating
-- an account also creates an auth.users row, so it goes through the admin path
-- in the Edge Function, never straight from a browser.
create policy users_admin_update on public.users
  for update to authenticated
  using (public.app_is_admin())
  with check (public.app_is_admin());

-- --- user_codes ------------------------------------------------------------
-- No policies, on purpose. Every read through the public key returns nothing.

-- --- login_attempts --------------------------------------------------------
-- No policies, on purpose.

-- --- service_advisors ------------------------------------------------------
-- Readable by everyone signed in, television included: the board renders the
-- advisor's NAME beside their colour, always, because twelve hues cannot all be
-- told apart by a dichromat and colour must stay a grouping aid rather than the
-- identifier. Do not drop the name to tidy the layout.
create policy advisors_select on public.service_advisors
  for select to authenticated
  using (public.app_is_active());

create policy advisors_admin_all on public.service_advisors
  for all to authenticated
  using (public.app_is_admin())
  with check (public.app_is_admin());

-- --- key_tags --------------------------------------------------------------
-- Everyone signed in reads every row. The television reads LIVE ROWS ONLY: it
-- renders a board, it has no screen that shows history, and an account that
-- cannot use a thing should not be able to read it.
--
-- This was very nearly written the other way round, and the reason is worth
-- recording because it decided the whole update mechanism.
--
-- With Supabase realtime, this narrow policy does not work. Realtime evaluates
-- the policy against the NEW row, so the moment a key is checked out the row
-- stops matching and the update is never delivered — the television, having
-- heard nothing, leaves the tag up indefinitely. Keeping the policy tight would
-- have meant letting the display read returned and voided rows just so that it
-- could be told about them.
--
-- The app polls instead (see board_version() in section 6), which has no such
-- constraint, so the policy stays where it belongs. Polling also answers the
-- staleness problem better than realtime does: a failed request is an immediate
-- and unambiguous signal, whereas a quiet WebSocket looks exactly like a quiet
-- afternoon.
create policy key_tags_select on public.key_tags
  for select to authenticated
  using (
    public.app_is_active()
    and (status = 'held' or not public.app_is_display())
  );

-- No insert, update, or delete policy exists for anyone. All writes go through
-- section 6.

-- --- key_tag_events --------------------------------------------------------
-- Not the television's business. It renders a board; it has no view that shows
-- history, and an account that cannot use a thing should not be able to read it.
create policy key_events_select on public.key_tag_events
  for select to authenticated
  using (public.app_is_active() and not public.app_is_display());

-- No write policy. Only the operations in section 6 append here.


-- ============================================================================
-- 6. Operations
--
-- Every state change lives here, as a SECURITY DEFINER function that checks
-- permissions itself and writes the event log. Concentrating writes in one
-- place is what makes the rules testable: there is no second path to audit.
--
-- Each raises on refusal rather than returning quietly, so a rejected action
-- can never be mistaken by the app for a successful one.
-- ============================================================================

-- Resolve the caller once, refusing deactivated and logged-out callers.
create or replace function public.app_require_user()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from public.users where id = auth.uid() and active;
  if v_id is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  return v_id;
end;
$$;

-- Which advisor a key tag belongs to. Copied from dispatch unchanged.
--
--   3 characters or fewer -> nobody. Three is a tow-in; fewer is a mistyped tag.
--   starts with T         -> nobody. The car was towed in.
--   otherwise             -> the active advisor holding that first character,
--                            or nobody if it matches none of them.
--
-- Returning null for an unmatched character rather than raising is deliberate:
-- a cashier holding a real tag must never be blocked because the advisor list is
-- out of date. The board renders it as "Unknown" so it is visible instead of
-- silent. In this project that matters more than it does in dispatch, because
-- this advisor list is a copy and copies go stale (PLAN.md section 9).
create or replace function public.advisor_for_code(p_code text)
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  v_code  text := upper(trim(coalesce(p_code, '')));
  v_first text;
begin
  if length(v_code) <= 3 then return null; end if;
  v_first := left(v_code, 1);
  if v_first = 'T' then return null; end if;
  return (select id from public.service_advisors
           where active and key_char = v_first limit 1);
end;
$$;


-- --- advisor colours --------------------------------------------------------
-- Twelve hues, evenly spaced in OKLCH. Copied from dispatch so an advisor is the
-- same colour on both screens — a cashier looking from the tablet to the
-- television should not have to re-learn who is orange.
--
-- Twelve cannot all be distinguished by someone with red-green colour blindness,
-- about one man in twelve; two pairs collapse under simulation. That is a
-- ceiling, not a defect — the real limit for a dichromat is around five. It is
-- why the advisor's NAME is always rendered beside the colour, and why colour
-- must stay a grouping aid rather than the identifier.
create or replace function public.advisor_palette()
returns table(ord int, color text)
language sql immutable as $$
  select * from (values
    ( 1, '#d05a69'), ( 2, '#cd632d'), ( 3, '#b97600'), ( 4, '#958900'),
    ( 5, '#5c9932'), ( 6, '#00a16f'), ( 7, '#00a0a2'), ( 8, '#0096c9'),
    ( 9, '#4087de'), (10, '#7f76dc'), (11, '#a867c3'), (12, '#c35c9b')
  ) as t(ord, color);
$$;

-- The next colour to hand out: the palette entry used by the fewest ACTIVE
-- advisors, earliest in the palette breaking ties.
--
-- Counting only active advisors is what frees a colour on removal — deactivate
-- somebody and their colour is available again with nothing to unbind by hand.
-- Returning the least-used rather than only an unused one means a thirteenth
-- advisor gets a shared colour instead of an error.
--
-- VOLATILE, and that matters. A STABLE function reads the snapshot from the
-- start of the statement, so inserting several advisors in one command would
-- hand every one of them the same colour — each call blind to the rows created
-- alongside it. Dispatch shipped that bug and caught it in testing.
create or replace function public.next_free_advisor_color()
returns text
language sql volatile security definer set search_path = '' as $$
  select p.color
    from public.advisor_palette() p
    left join public.service_advisors sa
           on sa.color = p.color and sa.active
   group by p.ord, p.color
   order by count(sa.id), p.ord
   limit 1;
$$;

create or replace function public.assign_advisor_color()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Insert with no colour: assign one. Runs BEFORE the NOT NULL check, so
  -- callers can simply omit the column.
  if tg_op = 'INSERT' and new.color is null then
    new.color := public.next_free_advisor_color();

  -- Reactivating somebody whose colour was handed to someone else while they
  -- were inactive: give them a fresh one rather than a silent duplicate.
  elsif tg_op = 'UPDATE' and new.active and not old.active
        and exists (select 1 from public.service_advisors
                     where active and color = new.color and id <> new.id) then
    new.color := public.next_free_advisor_color();
  end if;

  return new;
end;
$$;

drop trigger if exists advisor_color on public.service_advisors;
create trigger advisor_color
  before insert or update on public.service_advisors
  for each row execute function public.assign_advisor_color();


-- --- check in ---------------------------------------------------------------
-- The hot path. One field, no confirmation: the confirmation is that the tag is
-- now on the wall.
create or replace function public.check_in_key(p_tag text)
returns public.key_tags
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := public.app_require_user();
  v_tag  text := upper(trim(coalesce(p_tag, '')));
  v_row  public.key_tags;
  v_when timestamptz;
begin
  if not public.app_can_handle_keys() then
    raise exception 'This screen cannot take keys in' using errcode = '42501';
  end if;

  if v_tag = '' then
    raise exception 'Type a key tag first' using errcode = '22023';
  end if;

  if v_tag !~ '^[0-9A-Z]{1,12}$' then
    raise exception 'A key tag is letters and digits only' using errcode = '22023';
  end if;

  -- The insert is the duplicate check. Asking "is it already there?" first and
  -- then inserting is two statements with a gap in the middle, and the gap is
  -- exactly where the second tap lands.
  begin
    insert into public.key_tags (tag, advisor_id, checked_in_by)
    values (v_tag, public.advisor_for_code(v_tag), v_uid)
    returning * into v_row;
  exception when unique_violation then
    -- Read the time back for the message. It can legitimately come back null if
    -- the other key was handed over in the moment between the failed insert and
    -- this select, so the message degrades rather than reading "checked in at ".
    select checked_in_at into v_when
      from public.key_tags where tag = v_tag and status = 'held';

    if v_when is null then
      raise exception 'Key % is already on the board', v_tag using errcode = 'PT409';
    end if;

    raise exception 'Key % is already on the board, checked in at %',
      v_tag,
      to_char(v_when at time zone public.app_timezone(), 'FMHH12:MI am')
      using errcode = 'PT409';
  end;

  insert into public.key_tag_events (key_tag_id, event, actor_id)
  values (v_row.id, 'checked_in', v_uid);

  return v_row;
end;
$$;


-- --- check out --------------------------------------------------------------
-- The liability moment: this is a customer's key going back to them.
--
-- `and status = 'held'` is the same trick dispatch uses for claiming. A second
-- release of the same key matches zero rows and is told so, rather than quietly
-- overwriting the first one's timestamp and losing when the key actually left.
create or replace function public.check_out_key(p_id uuid)
returns public.key_tags
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := public.app_require_user();
  v_row   public.key_tags;
  v_prior public.key_tags;
begin
  if not public.app_can_handle_keys() then
    raise exception 'This screen cannot give keys back' using errcode = '42501';
  end if;

  update public.key_tags
     set status = 'returned', returned_at = now(), returned_by = v_uid
   where id = p_id and status = 'held'
  returning * into v_row;

  if not found then
    select * into v_prior from public.key_tags where id = p_id;

    if v_prior.id is null then
      raise exception 'No such key' using errcode = '22023';
    elsif v_prior.status = 'returned' then
      raise exception 'Key % was already given back at %',
        v_prior.tag,
        to_char(v_prior.returned_at at time zone public.app_timezone(), 'FMHH12:MI am')
        using errcode = 'PT409';
    else
      raise exception 'Key % was voided and is not on the board', v_prior.tag
        using errcode = 'PT409';
    end if;
  end if;

  insert into public.key_tag_events (key_tag_id, event, actor_id)
  values (v_row.id, 'returned', v_uid);

  return v_row;
end;
$$;


-- --- check out by tag -------------------------------------------------------
-- The kiosk's fast path: the cashier is holding the tag and types it.
--
-- A separate function rather than "look up the id, then call check_out_key",
-- because that is two statements and the row can change between them. This stays
-- one conditional write, and the unique index above is what guarantees the tag
-- identifies at most one live row.
create or replace function public.check_out_key_by_tag(p_tag text)
returns public.key_tags
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := public.app_require_user();
  v_tag text := upper(trim(coalesce(p_tag, '')));
  v_row public.key_tags;
begin
  if not public.app_can_handle_keys() then
    raise exception 'This screen cannot give keys back' using errcode = '42501';
  end if;

  update public.key_tags
     set status = 'returned', returned_at = now(), returned_by = v_uid
   where tag = v_tag and status = 'held'
  returning * into v_row;

  if not found then
    raise exception 'Key % is not on the board', v_tag using errcode = 'PT409';
  end if;

  insert into public.key_tag_events (key_tag_id, event, actor_id)
  values (v_row.id, 'returned', v_uid);

  return v_row;
end;
$$;


-- --- void -------------------------------------------------------------------
-- The eraser. A mistyped tag is otherwise immortal: it can never be checked out,
-- because the key that would clear it says something different. On a whiteboard
-- a human reads the tag and self-corrects; here nothing does.
--
-- No time limit. The kiosk offers this as "Undo" for a minute after a check-in
-- and as "Void" with a reason afterwards, but a typo found three hours later is
-- the same mistake and deserves the same fix.
--
-- Held rows only. Once a key has genuinely gone back, that is history — if the
-- return was itself the mistake, the key is still here, so check it in again.
create or replace function public.void_key(p_id uuid, p_reason text)
returns public.key_tags
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := public.app_require_user();
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_row    public.key_tags;
  v_prior  public.key_tags;
begin
  if not public.app_can_handle_keys() then
    raise exception 'This screen cannot change the board' using errcode = '42501';
  end if;

  update public.key_tags
     set status = 'voided', voided_at = now(), voided_by = v_uid,
         void_reason = v_reason
   where id = p_id and status = 'held'
  returning * into v_row;

  if not found then
    select * into v_prior from public.key_tags where id = p_id;

    if v_prior.id is null then
      raise exception 'No such key' using errcode = '22023';
    elsif v_prior.status = 'returned' then
      raise exception 'Key % has already been given back. If it is still here, check it in again.',
        v_prior.tag using errcode = 'PT409';
    else
      raise exception 'Key % is already off the board', v_prior.tag using errcode = 'PT409';
    end if;
  end if;

  insert into public.key_tag_events (key_tag_id, event, actor_id, detail)
  values (v_row.id, 'voided', v_uid, v_reason);

  return v_row;
end;
$$;


-- --- login ------------------------------------------------------------------
-- Called only by the login Edge Function, which runs as service_role.
--
-- Compares against every active account rather than looking the code up, because
-- the hashes are salted. Deliberately does not say WHICH check failed: an
-- endpoint that distinguishes "no such code" from "wrong code" is a brute-force
-- oracle against the whole code space.
create or replace function public.verify_login_code(p_code text)
returns uuid
language sql stable security definer set search_path = '' as $$
  select u.id
    from public.users u
    join public.user_codes c on c.user_id = u.id
   where u.active
     and c.code_hash = extensions.crypt(p_code, c.code_hash)
   limit 1;
$$;

-- Sets or resets a code. service_role only, called by the admin path.
--
-- The length check lives here rather than only in the app because this is the
-- one place a code can be set. A short code slipped in through a script would
-- silently undo the reasoning in app_code_length().
create or replace function public.set_login_code(p_user_id uuid, p_code text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_len int := public.app_code_length();
begin
  if p_code !~ ('^[0-9]{' || v_len || '}$') then
    raise exception 'A login code must be exactly % digits', v_len using errcode = '22023';
  end if;

  insert into public.user_codes (user_id, code_hash, updated_at)
  values (p_user_id, extensions.crypt(p_code, extensions.gen_salt('bf', 10)), now())
  on conflict (user_id)
  do update set code_hash = excluded.code_hash, updated_at = now();
end;
$$;


-- --- the board --------------------------------------------------------------
-- What the television renders, in one query: every live key, oldest first,
-- with its advisor already resolved.
--
-- security_invoker = true means this view is subject to the CALLER's policies
-- rather than the view owner's. Without it a view is a hole straight through
-- section 5 — the classic way a carefully written set of policies turns out to
-- be bypassable by selecting from something else.
--
-- Oldest first is the whole sort. A key that has been sitting for two days
-- drifts to the top of its column on its own, with no rule to write and nothing
-- to configure.
drop view if exists public.board;
create view public.board with (security_invoker = true) as
  select k.id,
         k.tag,
         k.tag_type,
         k.checked_in_at,
         sa.id         as advisor_id,
         sa.name       as advisor_name,
         sa.color      as advisor_color,
         -- So the columns sit in the same order every time. Sorting them by
         -- name instead would be fine until an advisor is added, at which point
         -- the whole board rearranges itself and everybody has to re-learn
         -- where to look.
         sa.sort_order as advisor_sort
    from public.key_tags k
    left join public.service_advisors sa on sa.id = k.advisor_id
   where k.status = 'held'
   order by k.checked_in_at;


-- --- is the board different from last time? ---------------------------------
-- What the television polls, every couple of seconds, instead of refetching the
-- whole board. Two numbers, about sixty bytes.
--
-- WHY NOT REALTIME. A WebSocket delivers updates instantly and for free, and it
-- was the original design. Two things ruled it out:
--
--   1. It cannot deliver a row that leaves the caller's policy, so the display
--      would have had to be allowed to read returned keys purely to be told
--      they had been returned. Polling keeps key_tags_select tight.
--   2. A dead socket is silent, and so is a quiet afternoon. On a television
--      those must not look the same. A poll that fails is unambiguous, and the
--      board can say so on screen within seconds.
--
-- WHY NOT JUST POLL THE BOARD. Fifty rows is roughly 7KB; every three seconds
-- for a screen that is on all day is about 4GB a month, against a 5GB free tier.
-- This is the cheap half of that: poll this, refetch the board only when it
-- moves.
--
-- SECURITY DEFINER on purpose. It must count rows the display cannot see —
-- otherwise a check-out would not change the answer and the board would never
-- learn to remove the tag. What it exposes is a count the display already has
-- and one timestamp.
--
-- greatest() ignores nulls, so an unreturned key contributes its check-in time
-- and nothing else.
create or replace function public.board_version()
returns table(held bigint, latest timestamptz)
language sql stable security definer set search_path = '' as $$
  select count(*) filter (where status = 'held'),
         max(greatest(checked_in_at, returned_at, voided_at))
    from public.key_tags;
$$;


-- ============================================================================
-- 7. Grants
--
-- RLS decides which rows; grants decide which tables and functions are reachable
-- at all. Both matter. These revokes are the second lock.
-- ============================================================================

-- --- Functions: default-deny, then grant back deliberately ------------------
--
-- PostgreSQL grants EXECUTE on a NEW function to PUBLIC automatically, and
-- Supabase's default privileges hand it to anon. That means every function added
-- to this file in future is exposed to anonymous callers unless somebody
-- remembers to revoke it, and eventually somebody will not. Dispatch learned
-- this the hard way: advisor_for_code() was callable without a login, and being
-- SECURITY DEFINER it read straight past RLS.
--
-- Sweeping first and granting back makes forgetting safe instead of dangerous.
revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;

-- The permission helpers are named inside the RLS policies, and policy
-- expressions run with the CALLER's privileges — without these grants every
-- policy fails and the app stops working entirely. Each reports only the
-- caller's own permissions, which they can already see in their own session.
grant execute on function public.app_is_active()       to authenticated;
grant execute on function public.app_can_handle_keys() to authenticated;
grant execute on function public.app_is_display()      to authenticated;
grant execute on function public.app_is_admin()        to authenticated;

-- The operations.
grant execute on function public.check_in_key(text)         to authenticated;
grant execute on function public.check_out_key(uuid)        to authenticated;
grant execute on function public.check_out_key_by_tag(text) to authenticated;
grant execute on function public.void_key(uuid, text)       to authenticated;

-- Polled every couple of seconds by the television, so it is the most-called
-- function in the system by a wide margin. It reads two aggregates off a
-- partial index and returns one row.
grant execute on function public.board_version()            to authenticated;

-- --- service_role: the login path -------------------------------------------
--
-- These two are the reason login works at all, and they are easy to leave out.
--
-- The sweep above revokes EXECUTE from PUBLIC, and every role inherits PUBLIC —
-- service_role included. So the login function, which runs as service_role,
-- loses the ability to call the very functions it exists to call. It fails as a
-- 500 with "Login is temporarily unavailable" and a permission-denied line in
-- the function logs that nobody is looking at, on a screen whose only job is to
-- show a login box.
--
-- Neither is callable with the publishable key. Exposed to the internet,
-- verify_login_code() is a brute-force oracle against the whole code space and
-- set_login_code() rewrites anybody's credentials.
grant execute on function public.verify_login_code(text)    to service_role;
grant execute on function public.set_login_code(uuid, text) to service_role;

-- advisor_for_code() is deliberately NOT granted. Nothing in the app calls it —
-- check_in_key() uses it internally, and being SECURITY DEFINER it would let a
-- caller probe which key characters are assigned in a table they may only read
-- under policy. This is the exact function that leaked in dispatch.

-- --- Tables: nothing at all for logged-out callers --------------------------
--
-- Swept rather than enumerated, because Supabase grants anon access to every NEW
-- table in this schema by default and an enumerated list is a list somebody has
-- to remember to extend.
--
-- Nothing is granted back: anon has no business reading any of it. Every table
-- also has RLS with no anon policy, so this is the second lock, not the only one.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- --- service_role: say it out loud rather than inheriting it -----------------
-- The login and admin functions run as service_role. Supabase grants it
-- everything by default, which means the sweeps above can quietly take it away.
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;

-- --- authenticated: swept and granted back, same as the other two -----------
--
-- Supabase grants `authenticated` everything on every table in this schema by
-- default. Writing "revoke insert, update, delete on the tables I happen to be
-- thinking about" leaves the default in charge of the rest, and the next table
-- added to this file arrives fully writable with nothing to say so.
--
-- More subtly, the opposite mistake is just as quiet: relying on the DEFAULT for
-- a grant the app genuinely needs. The admin policies below are useless without
-- an UPDATE grant to go with them, and if that grant is inherited rather than
-- stated, a later sweep removes it and the admin screen simply stops working
-- with no error that names the cause. Dispatch lost service_role's grants that
-- way and only noticed because notifications went quiet.
--
-- So: revoke everything, then say out loud what each table allows.
revoke all on all tables     in schema public from authenticated;
revoke all on all sequences  in schema public from authenticated;
alter default privileges in schema public revoke all on tables    from authenticated;
alter default privileges in schema public revoke all on sequences from authenticated;

-- Read your own row (or all of them, as John). UPDATE is granted so that
-- users_admin_update can work at all; the policy is what limits it to John, and
-- a non-admin's update matches zero rows.
grant select, update on public.users to authenticated;

-- Read by everyone signed in; written only by John, per advisors_admin_all.
grant select, insert, update, delete on public.service_advisors to authenticated;

-- Read-only, all three. Every write goes through section 6, which runs as the
-- owner and does not need a grant here. There is deliberately no path from a
-- browser to an INSERT on key_tags.
grant select on public.key_tags       to authenticated;
grant select on public.key_tag_events to authenticated;
grant select on public.board          to authenticated;

-- No sequence grants. Nothing outside section 6 inserts, so nothing outside
-- section 6 needs a sequence.

-- Readable by nobody but the login function, which runs as service_role.
revoke all on public.user_codes     from authenticated;
revoke all on public.login_attempts from authenticated;


-- ============================================================================
-- 8. Self-check
--
-- Runs at the end of every paste. These are the mistakes that are invisible
-- afterwards: a table added without RLS, or a grant that a later sweep undid.
-- Raising here is the difference between finding out now and finding out from
-- somebody else.
-- ============================================================================

do $$
declare v_missing text;
begin
  select string_agg(c.relname, ', ')
    into v_missing
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

  if v_missing is not null then
    raise exception 'RLS is OFF on: %. Every row in those tables is readable by anyone on the internet.', v_missing;
  end if;
end $$;

do $$
declare v_leaky text;
begin
  select string_agg(distinct table_name, ', ')
    into v_leaky
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon';

  if v_leaky is not null then
    raise exception 'anon still holds grants on: %', v_leaky;
  end if;
end $$;

-- Function EXECUTE, both directions.
--
-- The sweep in section 7 revokes from PUBLIC, which every role inherits, so a
-- function that is not granted back afterwards is a function nobody can call.
-- Both failures are quiet in the worst way: login returns a 500 with the reason
-- only in the function logs, and a missing operation grant means a cashier taps
-- a button on a tablet and nothing happens.
do $$
declare v_missing text;
begin
  select string_agg(f.who || ' cannot execute ' || f.sig, '; ')
    into v_missing
    from (values
      ('service_role',  'public.verify_login_code(text)'),
      ('service_role',  'public.set_login_code(uuid, text)'),
      ('authenticated', 'public.check_in_key(text)'),
      ('authenticated', 'public.check_out_key(uuid)'),
      ('authenticated', 'public.check_out_key_by_tag(text)'),
      ('authenticated', 'public.void_key(uuid, text)'),
      ('authenticated', 'public.board_version()'),
      ('authenticated', 'public.app_is_active()'),
      ('authenticated', 'public.app_can_handle_keys()'),
      ('authenticated', 'public.app_is_display()'),
      ('authenticated', 'public.app_is_admin()')
    ) as f(who, sig)
   where not has_function_privilege(f.who, f.sig, 'execute');

  if v_missing is not null then
    raise exception 'Missing EXECUTE grants: %', v_missing;
  end if;
end $$;

-- And the other direction: anon must not be able to call anything at all. The
-- helpers are SECURITY DEFINER and read straight past RLS, so one of these
-- reachable without a login is a hole, not an inconvenience. This is the exact
-- mistake dispatch made with advisor_for_code().
do $$
declare v_exposed text;
begin
  select string_agg(p.proname || '()', ', ')
    into v_exposed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');

  if v_exposed is not null then
    raise exception 'anon can call: %. Every one of these runs past RLS.', v_exposed;
  end if;
end $$;

-- The board must be unwritable from a browser. RLS having no write policy and
-- the grant being absent are two independent locks, and this checks the second
-- one — the one a later "grant all on all tables" would quietly undo.
do $$
declare v_writable text;
begin
  select string_agg(distinct table_name || ' (' || privilege_type || ')', ', ')
    into v_writable
    from information_schema.role_table_grants
   where table_schema = 'public'
     and grantee = 'authenticated'
     and table_name in ('key_tags', 'key_tag_events')
     and privilege_type in ('INSERT', 'UPDATE', 'DELETE');

  if v_writable is not null then
    raise exception 'authenticated can write the board directly: %. Every write must go through section 6.', v_writable;
  end if;
end $$;

do $$
begin
  raise notice 'Key Board schema applied. RLS on every table, anon holds nothing, the board is read-only.';
end $$;
