-- ============================================================================
-- Key Board — what is actually true right now
-- ============================================================================
--
-- Read-only. Paste into the SQL editor any time; it changes nothing.
--
-- schema.sql already checks all of this and raises if something is wrong, but a
-- raise that did not happen is invisible, and the SQL editor does not show
-- NOTICE either — so a correct paste and a paste that quietly did half the file
-- both read as "Success. No rows returned".
--
-- This returns rows. Failures sort to the top.
-- ============================================================================

with checks as (

  select 'tables exist' as what,
         (select count(*)::text || ' of 6'
            from pg_tables
           where schemaname = 'public'
             and tablename in ('users','user_codes','login_attempts',
                               'service_advisors','key_tags','key_tag_events')) as found,
         (select count(*) = 6
            from pg_tables
           where schemaname = 'public'
             and tablename in ('users','user_codes','login_attempts',
                               'service_advisors','key_tags','key_tag_events')) as ok

  union all
  select 'RLS on every table',
         coalesce((select string_agg(c.relname, ', ')
                     from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relkind = 'r'
                      and not c.relrowsecurity), 'all of them'),
         not exists (select 1
                       from pg_class c join pg_namespace n on n.oid = c.relnamespace
                      where n.nspname = 'public' and c.relkind = 'r'
                        and not c.relrowsecurity)

  union all
  select 'user_codes has zero policies',
         (select count(*)::text || ' policies'
            from pg_policies where schemaname='public' and tablename='user_codes'),
         (select count(*) = 0
            from pg_policies where schemaname='public' and tablename='user_codes')

  union all
  select 'anon holds no table grants',
         (select coalesce(string_agg(distinct table_name, ', '), 'none')
            from information_schema.role_table_grants
           where table_schema='public' and grantee='anon'),
         not exists (select 1 from information_schema.role_table_grants
                      where table_schema='public' and grantee='anon')

  union all
  select 'anon can call no function',
         (select coalesce(string_agg(p.proname, ', '), 'none')
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')),
         not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname='public'
                        and has_function_privilege('anon', p.oid, 'execute'))

  union all
  select 'the board is read-only from a browser',
         (select coalesce(string_agg(distinct privilege_type, ', '), 'select only')
            from information_schema.role_table_grants
           where table_schema='public' and grantee='authenticated'
             and table_name in ('key_tags','key_tag_events')
             and privilege_type in ('INSERT','UPDATE','DELETE')),
         not exists (select 1 from information_schema.role_table_grants
                      where table_schema='public' and grantee='authenticated'
                        and table_name in ('key_tags','key_tag_events')
                        and privilege_type in ('INSERT','UPDATE','DELETE'))

  union all
  select 'service_role can run the login path',
         case when has_function_privilege('service_role','public.verify_login_code(text)','execute')
               and has_function_privilege('service_role','public.set_login_code(uuid, text)','execute')
              then 'yes' else 'NO — logins will 500' end,
         has_function_privilege('service_role','public.verify_login_code(text)','execute')
         and has_function_privilege('service_role','public.set_login_code(uuid, text)','execute')

  union all
  select 'signed-in users can run the operations',
         case when has_function_privilege('authenticated','public.check_in_key(text)','execute')
               and has_function_privilege('authenticated','public.check_out_key(uuid)','execute')
               and has_function_privilege('authenticated','public.check_out_key_by_tag(text)','execute')
               and has_function_privilege('authenticated','public.void_key(uuid, text)','execute')
              then 'all four' else 'SOMETHING IS MISSING' end,
         has_function_privilege('authenticated','public.check_in_key(text)','execute')
         and has_function_privilege('authenticated','public.check_out_key(uuid)','execute')
         and has_function_privilege('authenticated','public.check_out_key_by_tag(text)','execute')
         and has_function_privilege('authenticated','public.void_key(uuid, text)','execute')

  union all
  select 'one live key per tag is enforced',
         (select coalesce(string_agg(indexname, ', '), 'MISSING')
            from pg_indexes
           where schemaname='public' and indexname='key_tags_one_live_per_tag'),
         exists (select 1 from pg_indexes
                  where schemaname='public' and indexname='key_tags_one_live_per_tag')

  union all
  select 'a display account cannot hold a write flag',
         (select coalesce(string_agg(conname, ', '), 'MISSING')
            from pg_constraint where conname='display_is_read_only'),
         exists (select 1 from pg_constraint where conname='display_is_read_only')

  union all
  select 'the board version endpoint exists',
         case when has_function_privilege('authenticated','public.board_version()','execute')
              then 'yes' else 'MISSING — the television cannot poll' end,
         has_function_privilege('authenticated','public.board_version()','execute')

  union all
  select 'the television reads live rows only',
         (select coalesce(string_agg(policyname, ', '), 'MISSING')
            from pg_policies
           where schemaname='public' and tablename='key_tags'
             and qual like '%app_is_display%'),
         exists (select 1 from pg_policies
                  where schemaname='public' and tablename='key_tags'
                    and qual like '%app_is_display%')

  -- Informational. Zero here is correct until seed-advisors.sql has been run.
  union all
  select 'advisors seeded',
         (select count(*)::text || ' active' from public.service_advisors where active),
         (select count(*) = 9 from public.service_advisors where active)

  -- Informational. Zero until tools/accounts.py has been run.
  union all
  select 'accounts created',
         (select coalesce(count(*) filter (where is_admin)::text || ' admin, '
                       || count(*) filter (where can_handle_keys and not is_admin)::text || ' kiosk, '
                       || count(*) filter (where is_display)::text || ' display', 'none')
            from public.users where active),
         (select count(*) > 0 from public.users where active)
)

select case when ok then 'ok' else '>> FAILED' end as status,
       what,
       found
  from checks
 order by ok, what;
