-- ============================================================================
-- 004_reference_biomarkers.sql
-- HealthPulse - shared reference tables for lab interpretation
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 003_reports.sql
-- Safe to run more than once.
--
-- These three tables are what stop "is this value abnormal?" from being a
-- question for the model (docs/04-ai-pipeline.md stages 3-5). They are shared,
-- read-only to logged-in users, and written only by the service role.
-- ============================================================================

-- -------------------------------------------------------------- biomarkers --
create table if not exists public.biomarkers (
  code            text primary key,
  display_name    text not null,
  category        text not null,
  -- Every lab_results.value is converted into this unit before comparison.
  canonical_unit  text not null,
  -- true  = a high value is the concerning direction (LDL, HbA1c)
  -- false = a low value is the concerning direction (Haemoglobin, Vitamin D)
  -- null  = both directions matter (Sodium, Potassium, Calcium)
  higher_is_worse boolean,
  created_at      timestamptz not null default now(),
  constraint biomarkers_code_format check (code ~ '^[A-Z0-9_]+$')
);

comment on table public.biomarkers is
  'Canonical biomarker catalogue. code is the join key used everywhere else.';

create index if not exists idx_biomarkers_category
  on public.biomarkers (category);

-- ------------------------------------------------------ biomarker_synonyms --
create table if not exists public.biomarker_synonyms (
  -- Store the LOWERCASED, whitespace-squashed printed test name. The backend
  -- must apply the same normalisation before looking a name up.
  synonym        text primary key,
  biomarker_code text not null references public.biomarkers (code) on delete cascade,
  source         text,
  created_at     timestamptz not null default now(),
  constraint biomarker_synonyms_lowercase check (synonym = lower(synonym)),
  constraint biomarker_synonyms_not_blank check (length(btrim(synonym)) > 0)
);

comment on table public.biomarker_synonyms is
  'Printed lab test name -> canonical biomarker code (pipeline stage 3). '
  'Keys are lowercase; the backend lowercases and squashes spaces before lookup.';

create index if not exists idx_biomarker_synonyms_biomarker_code
  on public.biomarker_synonyms (biomarker_code);
-- Fuzzy fallback for names that are close but not an exact synonym. A trigram
-- hit is a SUGGESTION only: the row is still stored with needs_review = true.
create index if not exists idx_biomarker_synonyms_trgm
  on public.biomarker_synonyms using gin (synonym gin_trgm_ops);

-- --------------------------------------------------------- reference_ranges --
create table if not exists public.reference_ranges (
  id              uuid primary key default gen_random_uuid(),
  biomarker_code  text not null references public.biomarkers (code) on delete cascade,
  -- 'any' means the range does not vary by sex.
  sex             text not null default 'any',
  -- Age band in whole years, inclusive of age_min, inclusive of age_max.
  age_min         integer not null default 0,
  age_max         integer not null default 120,
  -- null = row applies whatever the pregnancy status.
  -- true / false = row applies only to that status and wins over the null row.
  pregnancy       boolean,
  -- All thresholds are expressed in biomarkers.canonical_unit.
  low             numeric,
  high            numeric,
  borderline_low  numeric,
  borderline_high numeric,
  critical_low    numeric,
  critical_high   numeric,
  -- MANDATORY. We must always be able to say where a threshold came from.
  source_citation text not null,
  created_at      timestamptz not null default now(),
  constraint reference_ranges_sex_check
    check (sex in ('male', 'female', 'any')),
  constraint reference_ranges_age_band_check
    check (age_min >= 0 and age_max >= age_min and age_max <= 120),
  constraint reference_ranges_citation_not_blank
    check (length(btrim(source_citation)) > 0),
  -- A row that says nothing is a bug, not a range.
  constraint reference_ranges_has_a_threshold
    check (num_nonnulls(low, high, borderline_low, borderline_high,
                        critical_low, critical_high) > 0),
  -- Ordering sanity, checked only where both sides are present.
  constraint reference_ranges_low_below_high
    check (low is null or high is null or low <= high),
  constraint reference_ranges_critical_low_below_low
    check (critical_low is null or low is null or critical_low <= low),
  constraint reference_ranges_critical_high_above_high
    check (critical_high is null or high is null or critical_high >= high),
  -- borderline_* sit BETWEEN the frank cut-off and normal, so the six numbers
  -- must always read in this order, ignoring the nulls:
  --   critical_low <= low <= borderline_low <= borderline_high <= high <= critical_high
  constraint reference_ranges_borderline_low_above_low
    check (borderline_low is null or low is null or borderline_low >= low),
  constraint reference_ranges_borderline_high_below_high
    check (borderline_high is null or high is null or borderline_high <= high)
);

comment on table public.reference_ranges is
  'Deterministic classification table (pipeline stage 4). Every row must carry '
  'a source_citation. If a threshold is not confidently sourced, the row is '
  'omitted and the gap is recorded in db/seed/GAPS.md.';
comment on column public.reference_ranges.pregnancy is
  'null = applies to any pregnancy status. A true/false row overrides the null row.';

create index if not exists idx_reference_ranges_biomarker_code
  on public.reference_ranges (biomarker_code);
create index if not exists idx_reference_ranges_lookup
  on public.reference_ranges (biomarker_code, sex, age_min, age_max);

-- NULLS NOT DISTINCT (PostgreSQL 15+) so the "applies to any pregnancy status"
-- row cannot be inserted twice.
create unique index if not exists uq_reference_ranges_band
  on public.reference_ranges (biomarker_code, sex, age_min, age_max, pregnancy)
  nulls not distinct;

-- ------------------------------------------------- deferred FK from 003 -----
-- lab_results.biomarker_code -> biomarkers.code. Added here because biomarkers
-- did not exist when lab_results was created.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'lab_results_biomarker_code_fkey'
      and conrelid = 'public.lab_results'::regclass
  ) then
    alter table public.lab_results
      add constraint lab_results_biomarker_code_fkey
      foreign key (biomarker_code) references public.biomarkers (code)
      on delete restrict;
  end if;
end
$$;

-- Index for that foreign key. The (user_id, biomarker_code, measured_on) index
-- in 003 does not cover it, because biomarker_code is not its leading column -
-- so a "which results use this biomarker?" lookup, and the FK's own check when a
-- biomarker row is touched, would both have to scan the table without this.
create index if not exists idx_lab_results_biomarker_code
  on public.lab_results (biomarker_code);
