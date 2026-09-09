-- ============================================================================
-- 003_reports.sql
-- HealthPulse - uploaded reports, model extractions, structured lab results
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 002_identity.sql
-- Safe to run more than once.
--
-- NOTE: lab_results.biomarker_code gets its foreign key to biomarkers(code) in
-- 004_reference_biomarkers.sql, because the biomarkers table does not exist yet.
-- ============================================================================

-- ----------------------------------------------------------------- reports --
create table if not exists public.reports (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  storage_path        text not null,
  -- SHA-256 hex digest of the uploaded bytes. Same file uploaded twice costs no
  -- model call (docs/04-ai-pipeline.md stage 1).
  file_hash           text not null,
  mime_type           text,
  report_type         text,
  lab_name            text,
  collected_on        date,
  status              text not null default 'uploaded',
  -- Original file is deleted after this date unless the user opts to keep it.
  keep_original_until date not null default (current_date + 90),
  created_at          timestamptz not null default now(),
  constraint reports_status_check
    check (status in ('uploaded', 'extracting', 'extracted', 'failed')),
  constraint reports_file_hash_format
    check (file_hash ~ '^[0-9a-f]{64}$')
);

comment on table public.reports is
  'One row per uploaded lab report / scan / prescription file.';
comment on column public.reports.file_hash is
  'Lowercase SHA-256 hex of the file bytes. Unique per user for dedupe.';

-- Dedupe: the same user cannot store the same file twice.
create unique index if not exists uq_reports_user_file_hash
  on public.reports (user_id, file_hash);

create index if not exists idx_reports_user_id
  on public.reports (user_id);
create index if not exists idx_reports_user_collected_on
  on public.reports (user_id, collected_on desc);
create index if not exists idx_reports_status
  on public.reports (status) where status in ('uploaded', 'extracting');
-- Nightly job that deletes expired original files.
create index if not exists idx_reports_keep_original_until
  on public.reports (keep_original_until);

-- ------------------------------------------------------- report_extractions --
create table if not exists public.report_extractions (
  id         uuid primary key default gen_random_uuid(),
  report_id  uuid not null references public.reports (id) on delete cascade,
  model      text not null,
  raw_json   jsonb not null,
  tokens_in  integer check (tokens_in is null or tokens_in >= 0),
  tokens_out integer check (tokens_out is null or tokens_out >= 0),
  created_at timestamptz not null default now()
);

comment on table public.report_extractions is
  'Raw structured JSON returned by the extraction model, kept verbatim so a '
  're-parse never needs another model call. Ownership is inherited from reports.';

create index if not exists idx_report_extractions_report_id
  on public.report_extractions (report_id);

-- ------------------------------------------------------------- lab_results --
create table if not exists public.lab_results (
  id                uuid primary key default gen_random_uuid(),
  -- Nullable + ON DELETE SET NULL on purpose: report FILES expire after
  -- keep_original_until, but the structured values are the trend history and
  -- must survive (docs/03-data-model.md, "Retention").
  report_id         uuid references public.reports (id) on delete set null,
  user_id           uuid not null references auth.users (id) on delete cascade,
  biomarker_code    text,
  value             numeric,
  unit              text,
  -- Exactly what the lab printed, kept for the "show me the original" view.
  printed_range     text,
  ref_low           numeric,
  ref_high          numeric,
  status            text,
  -- True when the printed test name could not be mapped to a biomarker code
  -- confidently. We never silently guess a health value.
  needs_review      boolean not null default false,
  confirmed_by_user boolean not null default false,
  measured_on       date,
  created_at        timestamptz not null default now(),
  constraint lab_results_status_check
    check (status is null or status in (
      'critical_low', 'low', 'borderline_low', 'normal',
      'borderline_high', 'high', 'critical_high')),
  -- A row with no biomarker_code must be flagged for review, never used silently.
  constraint lab_results_unmapped_needs_review
    check (biomarker_code is not null or needs_review)
);

comment on table public.lab_results is
  'One structured lab value. status is set by the deterministic classifier '
  '(docs/04-ai-pipeline.md stage 4), never by the model.';
comment on column public.lab_results.needs_review is
  'true = we could not map name or unit confidently; must be confirmed by user.';

create index if not exists idx_lab_results_user_id
  on public.lab_results (user_id);
create index if not exists idx_lab_results_report_id
  on public.lab_results (report_id);
-- The trend query: "show my HbA1c over 2 years".
create index if not exists idx_lab_results_user_biomarker_measured_on
  on public.lab_results (user_id, biomarker_code, measured_on desc);
-- The review queue.
create index if not exists idx_lab_results_user_needs_review
  on public.lab_results (user_id) where needs_review;
