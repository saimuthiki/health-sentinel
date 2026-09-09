-- ============================================================================
-- 101_storage.sql
-- HealthPulse - private "reports" storage bucket and its access policies
-- Target: Supabase Storage (PostgreSQL 15)
--
-- Run AFTER 100_rls.sql. Safe to run more than once.
--
-- The rule (docs/02-architecture.md section 6): report files are never publicly
-- addressable. The app never gets a public URL - it asks the backend for a
-- short-lived signed URL.
--
-- PATH CONVENTION - this is the whole security model, so it must be obeyed:
--
--     reports/<auth user id>/<report id>.<ext>
--
--   e.g. reports/6f1c9e0a-4b7e-4f8a-9f4a-1d2e3c4b5a60/2f8c....pdf
--
-- The first folder in the object name MUST be the owner's user id. The policies
-- below compare storage.foldername(name)[1] against auth.uid(), so a file saved
-- anywhere else is invisible and unwritable to everybody except the service role.
-- ============================================================================

-- ------------------------------------------------------------- the bucket --
-- public = false: no anonymous URL will ever resolve.
insert into storage.buckets (id, name, public)
values ('reports', 'reports', false)
on conflict (id) do update set public = false;

-- Supabase enables RLS on storage.objects by default; this makes it explicit so
-- the file is also correct on a plain Postgres server.
alter table storage.objects enable row level security;

-- ------------------------------------------------------------- read (own) --
drop policy if exists "reports_read_own" on storage.objects;
create policy "reports_read_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'reports'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ----------------------------------------------------------- upload (own) --
drop policy if exists "reports_insert_own" on storage.objects;
create policy "reports_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'reports'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------- replace (own) --
-- Both USING and WITH CHECK, so a file cannot be moved out of the owner's
-- folder by renaming it.
drop policy if exists "reports_update_own" on storage.objects;
create policy "reports_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'reports'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'reports'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ----------------------------------------------------------- delete (own) --
-- Needed for "delete all my health data" and for the 90-day file expiry when
-- the user triggers it from the app.
drop policy if exists "reports_delete_own" on storage.objects;
create policy "reports_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'reports'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- Deliberately NOT created:
--   * any policy for the `anon` role - there is no anonymous health data;
--   * any policy that makes the bucket listable;
--   * a service-role policy - the service role bypasses RLS already.
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from storage.buckets where id = 'reports' and public = false) then
    raise exception 'The reports bucket is missing or is PUBLIC. Stop and fix this.';
  end if;
  raise notice 'Private reports bucket present, 4 owner-scoped policies installed.';
end
$$;
