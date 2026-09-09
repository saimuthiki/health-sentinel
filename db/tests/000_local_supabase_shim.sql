-- ============================================================================
-- 000_local_supabase_shim.sql
-- ONLY FOR LOCAL / CI TESTING. **Do not run this on Supabase.**
--
-- Supabase already provides the auth schema, the storage schema and the
-- anon / authenticated / service_role database roles. This file creates just
-- enough of them on a plain PostgreSQL 15/16 server so that the migrations,
-- the policies and db/tests/rls_smoke.sql can be executed locally.
-- ============================================================================

create schema if not exists auth;
create schema if not exists storage;

-- Roles ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public  to anon, authenticated, service_role;
grant usage on schema auth    to anon, authenticated, service_role;
grant usage on schema storage to anon, authenticated, service_role;

-- auth.users ----------------------------------------------------------------
create table if not exists auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text unique,
  created_at timestamptz not null default now()
);
grant select on auth.users to authenticated, service_role;

-- auth.uid() / auth.role() --------------------------------------------------
-- Supabase derives these from the request JWT. Locally we read a GUC that the
-- test script sets with:  set local request.jwt.claim.sub = '<uuid>';
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  current_user::text);
$$;

-- storage.buckets / storage.objects -----------------------------------------
create table if not exists storage.buckets (
  id     text primary key,
  name   text not null,
  public boolean not null default false,
  owner  uuid,
  created_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets (id),
  name       text,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on storage.objects to authenticated;
grant select on storage.buckets to authenticated;

create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select (string_to_array(name, '/'))
           [1 : greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)];
$$;

-- Supabase's default privileges for new tables in public --------------------
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;
