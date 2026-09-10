-- ==========================================================================
-- Part 4 of 4 - check it worked
--
-- This one changes nothing. It only looks, and tells you whether the first
-- three parts did what they were supposed to.
--
-- Run it the same way: SQL Editor -> New query -> paste -> Run.
--
-- Every row should say PASS. If any row says CHECK, run that part again.
-- ==========================================================================

select
  'tables created' as what,
  count(*)::text || ' of 34' as found,
  case when count(*) = 34 then 'PASS' else 'CHECK - run Part 1 again' end as verdict
from pg_tables where schemaname = 'public'

union all
select
  'every table has security',
  count(*)::text || ' table(s) unprotected',
  case when count(*) = 0 then 'PASS' else 'CHECK - run Part 2 again' end
from pg_tables t
where t.schemaname = 'public'
  and not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = t.tablename and c.relrowsecurity
  )

union all
select
  'access policies created',
  count(*)::text || ' of 107',
  case when count(*) >= 107 then 'PASS' else 'CHECK - run Part 2 again' end
from pg_policies where schemaname = 'public'

union all
select
  'no table is locked with no way in',
  count(*)::text || ' table(s) have security on but no policy',
  case when count(*) = 0 then 'PASS' else 'CHECK - run Part 2 again' end
from pg_tables t
where t.schemaname = 'public'
  and exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = t.tablename and c.relrowsecurity
  )
  and not exists (
    select 1 from pg_policies p
    where p.schemaname = 'public' and p.tablename = t.tablename
  )

union all
select
  'private reports bucket exists',
  coalesce((select case when public then 'PUBLIC - wrong' else 'yes, private' end
            from storage.buckets where id = 'reports'), 'missing'),
  case when exists (select 1 from storage.buckets where id = 'reports' and public = false)
       then 'PASS' else 'CHECK - run Part 2 again' end

union all
select
  'storage policies created',
  count(*)::text || ' of 4',
  case when count(*) >= 4 then 'PASS' else 'CHECK - run Part 2 again' end
from pg_policies
where schemaname = 'storage' and tablename = 'objects' and policyname like 'reports_%'

union all
select
  'biomarkers loaded',
  count(*)::text || ' of 88',
  case when count(*) >= 88 then 'PASS' else 'CHECK - run Part 3 again' end
from public.biomarkers

union all
select
  'lab name synonyms loaded',
  count(*)::text || ' of 389',
  case when count(*) >= 389 then 'PASS' else 'CHECK - run Part 3 again' end
from public.biomarker_synonyms

union all
select
  'reference ranges loaded',
  count(*)::text || ' of 28',
  case when count(*) >= 28 then 'PASS' else 'CHECK - run Part 3 again' end
from public.reference_ranges

union all
select
  'every reference range cites a source',
  count(*)::text || ' uncited',
  case when count(*) = 0 then 'PASS' else 'CHECK - run Part 3 again' end
from public.reference_ranges
where source_citation is null or btrim(source_citation) = ''

union all
select
  'foods loaded',
  count(*)::text || ' of 147',
  case when count(*) >= 147 then 'PASS' else 'CHECK - run Part 3 again' end
from public.foods

union all
select
  'no synonym points at a missing biomarker',
  count(*)::text || ' orphaned',
  case when count(*) = 0 then 'PASS' else 'CHECK - run Part 3 again' end
from public.biomarker_synonyms s
left join public.biomarkers b on b.code = s.biomarker_code
where b.code is null;
