-- ============================================================================
-- 008_chat_audit.sql
-- HealthPulse - chat, audit trail, AI run ledger, deletion receipts
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 007_plans_grocery_alerts.sql
-- Safe to run more than once.
-- ============================================================================

-- ------------------------------------------------------------ chat_threads --
create table if not exists public.chat_threads (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  title      text,
  created_at timestamptz not null default now()
);

comment on table public.chat_threads is 'A conversation. One user, many threads.';

create index if not exists idx_chat_threads_user_id
  on public.chat_threads (user_id);
create index if not exists idx_chat_threads_user_created_at
  on public.chat_threads (user_id, created_at desc);

-- ----------------------------------------------------------- chat_messages --
create table if not exists public.chat_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.chat_threads (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        text not null,
  content     text not null default '',
  -- [{"type": "report", "report_id": "..."}, {"type": "image", "path": "..."}]
  attachments jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  constraint chat_messages_role_check
    check (role in ('user', 'assistant', 'system')),
  constraint chat_messages_attachments_is_array
    check (jsonb_typeof(attachments) = 'array')
);

comment on table public.chat_messages is
  'Chat turns. Kept until the user asks for deletion (docs/03-data-model.md).';

create index if not exists idx_chat_messages_user_id
  on public.chat_messages (user_id);
create index if not exists idx_chat_messages_thread_id
  on public.chat_messages (thread_id);
-- The screen query: load a thread oldest-first.
create index if not exists idx_chat_messages_thread_created_at
  on public.chat_messages (thread_id, created_at);

-- ------------------------------------------------- deferred FKs from 005 ----
-- symptoms.source_message_id and user_memory.source_message_id point at the
-- chat message they were extracted from. ON DELETE SET NULL: deleting a message
-- must not delete the symptom or the learned fact.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'symptoms_source_message_id_fkey'
      and conrelid = 'public.symptoms'::regclass
  ) then
    alter table public.symptoms
      add constraint symptoms_source_message_id_fkey
      foreign key (source_message_id) references public.chat_messages (id)
      on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'user_memory_source_message_id_fkey'
      and conrelid = 'public.user_memory'::regclass
  ) then
    alter table public.user_memory
      add constraint user_memory_source_message_id_fkey
      foreign key (source_message_id) references public.chat_messages (id)
      on delete set null;
  end if;
end
$$;

-- ----------------------------------------------------------- health_events --
create table if not exists public.health_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  event_type  text not null,
  payload     jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  constraint health_events_payload_is_object
    check (jsonb_typeof(payload) = 'object')
);

comment on table public.health_events is
  'APPEND-ONLY audit trail. Users may read and insert; there is deliberately no '
  'UPDATE or DELETE policy, so an audit row cannot be rewritten from the app. '
  'Account deletion is done by the service role, which bypasses RLS.';

create index if not exists idx_health_events_user_id
  on public.health_events (user_id);
create index if not exists idx_health_events_user_occurred_at
  on public.health_events (user_id, occurred_at desc);
create index if not exists idx_health_events_type
  on public.health_events (event_type, occurred_at desc);

-- ---------------------------------------------------------------- ai_runs --
create table if not exists public.ai_runs (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  task           text not null,
  model          text not null,
  -- HASH ONLY. Prompt contents are never stored (docs/03-data-model.md).
  prompt_hash    text,
  tokens_in      integer check (tokens_in is null or tokens_in >= 0),
  tokens_out     integer check (tokens_out is null or tokens_out >= 0),
  latency_ms     integer check (latency_ms is null or latency_ms >= 0),
  safety_verdict text,
  regenerated    boolean not null default false,
  created_at     timestamptz not null default now(),
  constraint ai_runs_prompt_hash_format
    check (prompt_hash is null or prompt_hash ~ '^[0-9a-f]{64}$')
);

comment on table public.ai_runs is
  'APPEND-ONLY cost and safety ledger for every model call. Prompt hashes only, '
  'never prompt contents. Retention 180 days.';
comment on column public.ai_runs.prompt_hash is
  'SHA-256 hex of the prompt. Used to spot repeats; cannot be reversed.';

create index if not exists idx_ai_runs_user_id
  on public.ai_runs (user_id);
create index if not exists idx_ai_runs_user_created_at
  on public.ai_runs (user_id, created_at desc);
create index if not exists idx_ai_runs_created_at
  on public.ai_runs (created_at);
create index if not exists idx_ai_runs_safety_verdict
  on public.ai_runs (safety_verdict, created_at desc);

-- ------------------------------------------------------- weekly_summaries --
create table if not exists public.weekly_summaries (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  week_start date not null,
  metrics    jsonb not null default '{}'::jsonb,
  narrative  text,
  model      text,
  created_at timestamptz not null default now(),
  constraint weekly_summaries_metrics_is_object
    check (jsonb_typeof(metrics) = 'object')
);

comment on table public.weekly_summaries is
  'One batched Gemini 2.5 Pro review per user per week.';

create unique index if not exists uq_weekly_summaries_user_week
  on public.weekly_summaries (user_id, week_start);
create index if not exists idx_weekly_summaries_user_id
  on public.weekly_summaries (user_id);
create index if not exists idx_weekly_summaries_user_week_start
  on public.weekly_summaries (user_id, week_start desc);

-- ------------------------------------------------------ deletion_requests --
create table if not exists public.deletion_requests (
  id              uuid primary key default gen_random_uuid(),
  -- ON DELETE SET NULL, not CASCADE: the receipt has to outlive the account it
  -- describes, otherwise "we deleted your data" has no evidence.
  user_id         uuid references auth.users (id) on delete set null,
  requested_at    timestamptz not null default now(),
  completed_at    timestamptz,
  objects_deleted integer check (objects_deleted is null or objects_deleted >= 0),
  rows_deleted    integer check (rows_deleted is null or rows_deleted >= 0)
);

comment on table public.deletion_requests is
  'Receipt for "delete all my health data". Survives the account it refers to.';

create index if not exists idx_deletion_requests_user_id
  on public.deletion_requests (user_id);
create index if not exists idx_deletion_requests_open
  on public.deletion_requests (requested_at) where completed_at is null;
