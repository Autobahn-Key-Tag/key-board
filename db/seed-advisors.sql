-- ============================================================================
-- Key Board — the service advisor list
-- ============================================================================
--
-- Run after schema.sql, in the SAME project. Safe to re-run: it adds anyone
-- missing and leaves everyone already here alone, including their colour.
--
-- THIS IS A COPY. Dispatch owns the real list (PLAN.md section 9). If an advisor
-- is added, renamed, or retired over there, it has to happen here too — that is
-- a runbook step, not something the database will do for you.
--
-- Nothing breaks when this list is stale: an unrecognised first character checks
-- the key in anyway and renders as "Unknown" in red. A cashier holding a real
-- tag is never stuck at the desk because paperwork is behind.
-- ============================================================================

-- Characters 5 and 7 are unassigned. That is not an omission — no advisor holds
-- them, so a tag starting with either reads as Unknown, which is correct and
-- visible. They are free for the next advisor hired.
do $$
declare
  v_advisor record;
begin
  -- One INSERT per iteration, deliberately. A single multi-row insert would
  -- give every advisor the same colour: next_free_advisor_color() counts rows
  -- that already exist, and inside one statement none of the others do yet.
  -- It is VOLATILE precisely so that a loop like this works.
  for v_advisor in
    select * from (values
      ('1', 'Anthony', 1),
      ('2', 'Mark',    2),
      ('3', 'Johnny',  3),
      ('4', 'Ralph',   4),
      ('6', 'Skip',    5),
      ('8', 'Josh',    6),
      ('9', 'Jovis',   7),
      ('0', 'Jimmy',   8),
      ('A', 'Igor',    9)
    ) as t(key_char, name, sort_order)
  loop
    -- Checked rather than ON CONFLICT so that re-running never touches an
    -- existing row. Somebody's colour may have been changed by hand, and a
    -- re-seed quietly putting it back would be the kind of thing that gets
    -- blamed on the app.
    if not exists (
      select 1 from public.service_advisors
       where key_char = v_advisor.key_char and active
    ) then
      insert into public.service_advisors (name, key_char, sort_order)
      values (v_advisor.name, v_advisor.key_char, v_advisor.sort_order);
    end if;
  end loop;
end $$;

-- What landed. Every advisor should have a DISTINCT colour: nine names into a
-- twelve-entry palette. Two sharing one means next_free_advisor_color() was
-- evaluated from a stale snapshot, which is the failure the loop above exists
-- to avoid — check it is still VOLATILE before blaming anything else.
select key_char, name, color, sort_order
  from public.service_advisors
 where active
 order by sort_order;
