-- ============================================================================
-- 002_identity.sql
-- HealthPulse - identity, profile, allergies, consent
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 001_extensions.sql, and Supabase's built-in auth.users table.
-- Safe to run more than once.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Controlled vocabularies used across the whole schema.
-- These are written out as CHECK constraints rather than Postgres ENUM types so
-- that adding a value later is a one-line ALTER instead of a type migration.
--
--   sex (profile)      male | female | other | prefer_not_to_say
--   sex (reference)    male | female | any
--   activity_level     sedentary | moderate | heavy      (ICMR-NIN 2020 groups)
--   meal_slot          breakfast | mid_morning | lunch | snack | dinner | bedtime
--
-- The backend MUST use exactly these strings.
-- ----------------------------------------------------------------------------

-- ---------------------------------------------------------------- profiles --
create table if not exists public.profiles (
  user_id       uuid primary key references auth.users (id) on delete cascade,
  display_name  text,
  locale        text        not null default 'en-IN',
  timezone      text        not null default 'Asia/Kolkata',
  created_at    timestamptz not null default now()
);

comment on table public.profiles is
  'Non-medical account profile. One row per auth user.';

-- --------------------------------------------------------- health_profiles --
create table if not exists public.health_profiles (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  dob            date,
  sex            text,
  height_cm      numeric(5,2) check (height_cm is null or (height_cm > 0 and height_cm < 300)),
  weight_kg      numeric(6,2) check (weight_kg is null or (weight_kg > 0 and weight_kg < 700)),
  activity_level text,
  diet_type      text,
  cuisine_pref   text[]      not null default '{}',
  city           text,
  pincode        text,
  wake_time      time,
  sleep_time     time,
  meal_times     jsonb       not null default '{}'::jsonb,
  conditions     text[]      not null default '{}',
  -- Not in the original sketch, added deliberately: reference_ranges is keyed by
  -- pregnancy status (see docs/04-ai-pipeline.md stage 4), so the profile has to
  -- be able to answer that question. Defaults to false; the user sets it.
  pregnancy      boolean     not null default false,
  updated_at     timestamptz not null default now(),
  constraint health_profiles_sex_check
    check (sex is null or sex in ('male', 'female', 'other', 'prefer_not_to_say')),
  constraint health_profiles_activity_level_check
    check (activity_level is null or activity_level in ('sedentary', 'moderate', 'heavy')),
  constraint health_profiles_diet_type_check
    check (diet_type is null or diet_type in ('veg', 'non_veg', 'egg', 'vegan', 'jain'))
);

comment on table public.health_profiles is
  'Clinical/dietary profile driving reference-range lookup and meal planning.';
comment on column public.health_profiles.pregnancy is
  'Pregnancy status. Used to pick the correct row from reference_ranges.';

drop trigger if exists trg_health_profiles_updated_at on public.health_profiles;
create trigger trg_health_profiles_updated_at
  before update on public.health_profiles
  for each row execute function public.set_updated_at();

-- --------------------------------------------------------------- allergies --
create table if not exists public.allergies (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  allergen   text not null,
  severity   text,
  created_at timestamptz not null default now(),
  constraint allergies_allergen_not_blank check (length(btrim(allergen)) > 0)
);

comment on table public.allergies is
  'User-declared food allergens. Hard filter on every candidate food list.';

create index if not exists idx_allergies_user_id
  on public.allergies (user_id);
create unique index if not exists uq_allergies_user_allergen
  on public.allergies (user_id, lower(btrim(allergen)));

-- ---------------------------------------------------------------- consents --
create table if not exists public.consents (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  consent_type text not null,
  version      text not null,
  accepted_at  timestamptz not null default now(),
  -- Hash only. We never store a raw IP address.
  ip_hash      text
);

comment on table public.consents is
  'Consent receipts. One row per (consent_type, version) the user accepted.';
comment on column public.consents.ip_hash is
  'Salted hash of the client IP. Never store the raw address.';

create index if not exists idx_consents_user_id
  on public.consents (user_id);
create unique index if not exists uq_consents_user_type_version
  on public.consents (user_id, consent_type, version);
