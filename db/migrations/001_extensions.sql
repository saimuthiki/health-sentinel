-- ============================================================================
-- 001_extensions.sql
-- HealthPulse - extensions and shared helpers
-- Target: PostgreSQL 15 (Supabase)
--
-- Run this FIRST. Safe to run more than once.
-- ============================================================================

-- pgcrypto gives us gen_random_uuid(). On Supabase it is normally already
-- installed in the "extensions" schema, in which case this line does nothing.
create extension if not exists pgcrypto;

-- pg_trgm powers fuzzy text search over food names and lab test names.
create extension if not exists pg_trgm;

-- ----------------------------------------------------------------------------
-- Shared trigger function: keeps updated_at honest.
-- Any table with an updated_at column gets a trigger that calls this.
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'BEFORE UPDATE trigger helper: stamps updated_at = now().';
