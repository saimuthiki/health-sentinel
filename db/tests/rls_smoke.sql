-- ============================================================================
-- rls_smoke.sql
-- HealthPulse - proof that Row Level Security actually isolates two users
--
-- WHAT THIS DOES
--   Creates two throwaway users, A and B. Logs in as each in turn, has each
--   create their own rows, and then checks - 20 separate assertions - that
--   neither can see, change or delete anything belonging to the other.
--
-- IT IS SAFE TO RUN ON A REAL DATABASE
--   Everything happens inside one transaction that ends with ROLLBACK, so when
--   the script finishes there is no test user, no test report and no test chat
--   left behind. Nothing is written permanently. If any assertion fails the
--   script stops with an error and the transaction is thrown away as well.
--
-- HOW TO RUN IT - Supabase SQL Editor (what the owner will do)
--   1. Open your project at supabase.com -> SQL Editor -> New query.
--   2. Open this file, select ALL of it, copy, paste into the editor.
--   3. Press Run.
--   4. Look at the "Messages"/"Notices" panel underneath the results.
--        Every line should read  "PASS: ...".
--        The last line should read  "ALL 20 RLS CHECKS PASSED".
--      If instead you see a red error box, RLS is not doing its job. Do not
--      ship. Re-run db/policies/100_rls.sql and try again.
--
-- HOW TO RUN IT - psql / CI
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/rls_smoke.sql
--   Exit code 0 means every check passed.
--
-- PREREQUISITES
--   All 8 migrations, both policy files, and 200_biomarkers.sql must already
--   have been run (the test writes a lab result for biomarker 'HB').
--   On a plain PostgreSQL server, run db/tests/000_local_supabase_shim.sql
--   first. On Supabase, do NOT run the shim - Supabase provides all of that.
-- ============================================================================

begin;

-- Two fixed, obviously-fake ids so nothing can collide with a real account.
-- Fake e-mail addresses on the reserved .invalid domain. No real personal data.
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'rls-test-a@example.invalid'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'rls-test-b@example.invalid')
on conflict (id) do nothing;

-- From here on we stop being the database owner and become an ordinary logged-in
-- user, which is the only way RLS can be tested honestly.
set local role authenticated;


-- ###########################################################################
-- Act as user A and create A's data.
-- (Supabase reads the signed-in user from the request JWT. Both GUC spellings
--  are set because auth.uid() accepts either.)
-- ###########################################################################
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);

insert into public.profiles (user_id, display_name)
values ('aaaaaaaa-0000-4000-8000-000000000001', 'Test User A');

insert into public.reports (id, user_id, storage_path, file_hash, mime_type, status)
values ('a0000000-0000-4000-8000-00000000000a',
        'aaaaaaaa-0000-4000-8000-000000000001',
        'aaaaaaaa-0000-4000-8000-000000000001/report-a.pdf',
        repeat('a', 64), 'application/pdf', 'extracted');

insert into public.report_extractions (report_id, model, raw_json)
values ('a0000000-0000-4000-8000-00000000000a', 'test-model', '{"rows": []}'::jsonb);

insert into public.lab_results (report_id, user_id, biomarker_code, value, unit, measured_on)
values ('a0000000-0000-4000-8000-00000000000a',
        'aaaaaaaa-0000-4000-8000-000000000001', 'HB', 13.5, 'g/dL', current_date);

insert into public.chat_threads (id, user_id, title)
values ('a0000000-0000-4000-8000-00000000000c',
        'aaaaaaaa-0000-4000-8000-000000000001', 'A private thread');

insert into public.chat_messages (thread_id, user_id, role, content)
values ('a0000000-0000-4000-8000-00000000000c',
        'aaaaaaaa-0000-4000-8000-000000000001', 'user', 'A secret message');


-- ###########################################################################
-- Act as user B and create B's data.
-- ###########################################################################
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claims',
  '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', true);

insert into public.profiles (user_id, display_name)
values ('bbbbbbbb-0000-4000-8000-000000000002', 'Test User B');

insert into public.reports (id, user_id, storage_path, file_hash, mime_type, status)
values ('b0000000-0000-4000-8000-00000000000b',
        'bbbbbbbb-0000-4000-8000-000000000002',
        'bbbbbbbb-0000-4000-8000-000000000002/report-b.pdf',
        repeat('b', 64), 'application/pdf', 'extracted');

insert into public.report_extractions (report_id, model, raw_json)
values ('b0000000-0000-4000-8000-00000000000b', 'test-model', '{"rows": []}'::jsonb);

insert into public.lab_results (report_id, user_id, biomarker_code, value, unit, measured_on)
values ('b0000000-0000-4000-8000-00000000000b',
        'bbbbbbbb-0000-4000-8000-000000000002', 'HB', 9.1, 'g/dL', current_date);

insert into public.chat_threads (id, user_id, title)
values ('b0000000-0000-4000-8000-00000000000d',
        'bbbbbbbb-0000-4000-8000-000000000002', 'B private thread');

insert into public.chat_messages (thread_id, user_id, role, content)
values ('b0000000-0000-4000-8000-00000000000d',
        'bbbbbbbb-0000-4000-8000-000000000002', 'user', 'B secret message');


-- ###########################################################################
-- Back to being user A. Everything below is what A can actually reach.
-- ###########################################################################
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claims',
  '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);

do $$
declare
  a_id  uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  b_id  uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
  n     integer;
  hit   boolean;
  passed integer := 0;
begin
  if auth.uid() is distinct from a_id then
    raise exception 'SETUP FAILED: auth.uid() is % but should be %', auth.uid(), a_id;
  end if;
  raise notice 'PASS  0: we are logged in as user A';

  -- ---------------------------------------------------------------- SELECT --
  select count(*) into n from public.profiles;
  if n <> 1 then raise exception 'FAIL 1: A sees % profiles, expected exactly 1 (their own)', n; end if;
  passed := passed + 1;
  raise notice 'PASS  1: profiles - A sees only their own row';

  select count(*) into n from public.profiles where user_id = b_id;
  if n <> 0 then raise exception 'FAIL 2: A can read user B''s profile'; end if;
  passed := passed + 1;
  raise notice 'PASS  2: profiles - B''s row is invisible to A';

  select count(*) into n from public.reports;
  if n <> 1 then raise exception 'FAIL 3: A sees % reports, expected 1', n; end if;
  passed := passed + 1;
  raise notice 'PASS  3: reports - A sees only their own row';

  select count(*) into n from public.reports where user_id = b_id;
  if n <> 0 then raise exception 'FAIL 4: A can read user B''s report'; end if;
  passed := passed + 1;
  raise notice 'PASS  4: reports - B''s report is invisible to A';

  select count(*) into n from public.lab_results;
  if n <> 1 then raise exception 'FAIL 5: A sees % lab results, expected 1', n; end if;
  passed := passed + 1;
  raise notice 'PASS  5: lab_results - A sees only their own value';

  select count(*) into n from public.lab_results where value = 9.1;
  if n <> 0 then raise exception 'FAIL 6: A can read user B''s haemoglobin value'; end if;
  passed := passed + 1;
  raise notice 'PASS  6: lab_results - B''s haemoglobin is invisible to A';

  -- Indirectly owned: no user_id column at all, ownership comes from reports.
  select count(*) into n from public.report_extractions;
  if n <> 1 then raise exception 'FAIL 7: A sees % report_extractions, expected 1', n; end if;
  passed := passed + 1;
  raise notice 'PASS  7: report_extractions - inherited ownership works (A sees 1)';

  select count(*) into n
  from public.report_extractions
  where report_id = 'b0000000-0000-4000-8000-00000000000b';
  if n <> 0 then raise exception 'FAIL 8: A can read the extraction of B''s report'; end if;
  passed := passed + 1;
  raise notice 'PASS  8: report_extractions - B''s extraction is invisible to A';

  select count(*) into n from public.chat_threads;
  if n <> 1 then raise exception 'FAIL 9: A sees % chat threads, expected 1', n; end if;
  passed := passed + 1;
  raise notice 'PASS  9: chat_threads - A sees only their own thread';

  select count(*) into n from public.chat_messages;
  if n <> 1 then raise exception 'FAIL 10: A sees % chat messages, expected 1', n; end if;
  passed := passed + 1;
  raise notice 'PASS 10: chat_messages - A sees only their own message';

  select count(*) into n from public.chat_messages where content = 'B secret message';
  if n <> 0 then raise exception 'FAIL 11: A can read user B''s chat message'; end if;
  passed := passed + 1;
  raise notice 'PASS 11: chat_messages - B''s message is invisible to A';

  -- The blunt version of the same question: a deliberate cross-user join.
  select exists (
    select 1
    from public.chat_threads t
    join public.chat_messages m on m.thread_id = t.id
    where t.user_id = b_id or m.user_id = b_id
  ) into hit;
  if hit then raise exception 'FAIL 12: a join reached user B''s data'; end if;
  passed := passed + 1;
  raise notice 'PASS 12: a deliberate cross-user join returns nothing';

  -- ---------------------------------------------------------------- UPDATE --
  update public.profiles set display_name = 'hacked' where user_id = b_id;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 13: A updated % of user B''s profile rows', n; end if;
  passed := passed + 1;
  raise notice 'PASS 13: A cannot UPDATE user B''s profile';

  update public.lab_results set value = 1 where user_id = b_id;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 14: A updated % of user B''s lab results', n; end if;
  passed := passed + 1;
  raise notice 'PASS 14: A cannot UPDATE user B''s lab results';

  -- ---------------------------------------------------------------- DELETE --
  delete from public.reports where user_id = b_id;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 15: A deleted % of user B''s reports', n; end if;
  passed := passed + 1;
  raise notice 'PASS 15: A cannot DELETE user B''s reports';

  delete from public.chat_messages where user_id = b_id;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 16: A deleted % of user B''s chat messages', n; end if;
  passed := passed + 1;
  raise notice 'PASS 16: A cannot DELETE user B''s chat messages';

  -- ---------------------------------------------------------------- INSERT --
  -- Writing a row that claims to belong to B must be refused outright.
  begin
    insert into public.lab_results (user_id, biomarker_code, value, unit, measured_on)
    values (b_id, 'HB', 99, 'g/dL', current_date);
    raise exception 'FAIL 17: A was allowed to INSERT a lab result owned by B';
  exception
    when insufficient_privilege then
      passed := passed + 1;
      raise notice 'PASS 17: A cannot INSERT a row owned by B (RLS WITH CHECK refused it)';
  end;

  -- Planting a message into B's thread must be refused too, even though the
  -- row would carry A's own user_id. This is the indirect-ownership check.
  begin
    insert into public.chat_messages (thread_id, user_id, role, content)
    values ('b0000000-0000-4000-8000-00000000000d', a_id, 'user', 'planted');
    raise exception 'FAIL 18: A was allowed to INSERT into B''s chat thread';
  exception
    when insufficient_privilege then
      passed := passed + 1;
      raise notice 'PASS 18: A cannot INSERT into B''s chat thread';
  end;

  -- ------------------------------------------------------- reference tables --
  select count(*) into n from public.biomarkers;
  if n = 0 then raise exception 'FAIL 19: A cannot read the shared biomarkers table'; end if;
  passed := passed + 1;
  raise notice 'PASS 19: reference data is readable by a logged-in user (% biomarkers)', n;

  begin
    insert into public.biomarkers (code, display_name, category, canonical_unit)
    values ('RLS_TEST_JUNK', 'junk', 'junk', 'junk');
    raise exception 'FAIL 20: A was allowed to WRITE to the shared biomarkers table';
  exception
    when insufficient_privilege then
      passed := passed + 1;
      raise notice 'PASS 20: A cannot WRITE to reference data (service role only)';
  end;

  raise notice '--------------------------------------------------';
  raise notice 'ALL % RLS CHECKS PASSED', passed;
  raise notice '--------------------------------------------------';
end
$$;

-- Nothing above is kept. This throws away both test users and all their rows.
rollback;

-- Proof that the rollback worked: both must be 0.
select
  (select count(*) from auth.users
    where email in ('rls-test-a@example.invalid', 'rls-test-b@example.invalid')) as leftover_test_users,
  (select count(*) from public.biomarkers where code = 'RLS_TEST_JUNK') as leftover_junk_rows;
