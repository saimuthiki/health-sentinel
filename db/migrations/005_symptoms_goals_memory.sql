-- ============================================================================
-- 005_symptoms_goals_memory.sql
-- HealthPulse - symptoms, follow-up questions, goals, learned memory
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 004_reference_biomarkers.sql
-- Safe to run more than once.
--
-- NOTE: symptoms.source_message_id and user_memory.source_message_id get their
-- foreign keys to chat_messages(id) in 008_chat_audit.sql.
-- ============================================================================

-- ---------------------------------------------------------------- symptoms --
create table if not exists public.symptoms (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  label             text not null,
  onset             date,
  severity          text,
  pattern           text,
  -- The chat message this symptom was extracted from, so the user can always
  -- see why we think they have it.
  source_message_id uuid,
  status            text not null default 'active',
  created_at        timestamptz not null default now(),
  constraint symptoms_label_not_blank check (length(btrim(label)) > 0)
);

comment on table public.symptoms is
  'Symptoms extracted from chat or entered by the user. Red-flag classification '
  'is done by deterministic rules (pipeline stage 5), never by the model.';

create index if not exists idx_symptoms_user_id
  on public.symptoms (user_id);
create index if not exists idx_symptoms_user_status
  on public.symptoms (user_id, status);
create index if not exists idx_symptoms_source_message_id
  on public.symptoms (source_message_id);

-- ------------------------------------------------------- symptom_followups --
create table if not exists public.symptom_followups (
  id          uuid primary key default gen_random_uuid(),
  symptom_id  uuid not null references public.symptoms (id) on delete cascade,
  question    text not null,
  answer      text,
  asked_at    timestamptz not null default now(),
  answered_at timestamptz
);

comment on table public.symptom_followups is
  'Clarifying questions asked about a symptom. Ownership inherited from symptoms.';

create index if not exists idx_symptom_followups_symptom_id
  on public.symptom_followups (symptom_id);
create index if not exists idx_symptom_followups_unanswered
  on public.symptom_followups (symptom_id) where answered_at is null;

-- ------------------------------------------------------------------- goals --
create table if not exists public.goals (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  goal_type  text not null,
  title      text not null,
  target     text,
  priority   text,
  status     text not null default 'active',
  created_at timestamptz not null default now(),
  closed_at  timestamptz,
  constraint goals_goal_type_check
    check (goal_type in ('weight', 'hair', 'skin', 'energy',
                         'sleep', 'fitness', 'deficiency'))
);

comment on table public.goals is
  'User goals that steer plan generation (pipeline stage 6).';

create index if not exists idx_goals_user_id
  on public.goals (user_id);
create index if not exists idx_goals_user_status
  on public.goals (user_id, status);

-- ------------------------------------------------------------- user_memory --
create table if not exists public.user_memory (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  fact              text not null,
  category          text,
  -- 0.00 - 1.00. Low-confidence facts must be confirmed by the user before they
  -- are allowed to influence a plan.
  confidence        numeric(4,3) not null default 0.500,
  confirmed         boolean not null default false,
  source_message_id uuid,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz,
  constraint user_memory_confidence_range
    check (confidence >= 0 and confidence <= 1),
  constraint user_memory_fact_not_blank check (length(btrim(fact)) > 0)
);

comment on table public.user_memory is
  'Atomic facts inferred from chat ("skips breakfast on workdays"). Inspectable '
  'and editable by the user; low-confidence rows are confirmed before use.';

create index if not exists idx_user_memory_user_id
  on public.user_memory (user_id);
-- The block the planner loads: live, usable facts for this user.
create index if not exists idx_user_memory_user_active
  on public.user_memory (user_id, category)
  where confirmed and expires_at is null;
create index if not exists idx_user_memory_expires_at
  on public.user_memory (expires_at) where expires_at is not null;
create index if not exists idx_user_memory_source_message_id
  on public.user_memory (source_message_id);
