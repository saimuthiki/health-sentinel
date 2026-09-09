-- ============================================================================
-- 007_plans_grocery_alerts.sql
-- HealthPulse - meal plans, grocery lists, pantry, alerts
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 006_nutrition.sql
-- Safe to run more than once.
-- ============================================================================

-- -------------------------------------------------------------- meal_plans --
create table if not exists public.meal_plans (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  plan_date    date not null,
  generated_at timestamptz not null default now(),
  model        text,
  -- Plain-English "why this plan looks like this" shown to the user.
  rationale    text,
  status       text not null default 'draft',
  constraint meal_plans_status_check
    check (status in ('draft', 'active', 'superseded', 'failed'))
);

comment on table public.meal_plans is
  'One plan per user per day. Screens read stored plans; we generate once a day.';

-- One plan per user per day keeps us inside the free tier.
create unique index if not exists uq_meal_plans_user_plan_date
  on public.meal_plans (user_id, plan_date);
create index if not exists idx_meal_plans_user_id
  on public.meal_plans (user_id);
create index if not exists idx_meal_plans_user_plan_date
  on public.meal_plans (user_id, plan_date desc);

-- --------------------------------------------------------- meal_plan_items --
create table if not exists public.meal_plan_items (
  id                 uuid primary key default gen_random_uuid(),
  meal_plan_id       uuid not null references public.meal_plans (id) on delete cascade,
  meal_slot          text not null,
  recipe_id          uuid references public.recipes (id) on delete set null,
  food_id            uuid references public.foods (id)   on delete set null,
  grams              numeric(8,2) check (grams is null or grams > 0),
  -- Recomputed in Python from the foods table (pipeline stage 7). Whatever the
  -- model claimed is discarded before this is written.
  computed_nutrients jsonb not null default '{}'::jsonb,
  why_text           text,
  order_index        integer not null default 0,
  created_at         timestamptz not null default now(),
  constraint meal_plan_items_meal_slot_check
    check (meal_slot in ('breakfast', 'mid_morning', 'lunch',
                         'snack', 'dinner', 'bedtime')),
  constraint meal_plan_items_needs_a_thing
    check (recipe_id is not null or food_id is not null),
  constraint meal_plan_items_nutrients_is_object
    check (jsonb_typeof(computed_nutrients) = 'object')
);

comment on table public.meal_plan_items is
  'One dish/food in a plan. computed_nutrients is always recomputed server-side.';

create index if not exists idx_meal_plan_items_meal_plan_id
  on public.meal_plan_items (meal_plan_id);
create index if not exists idx_meal_plan_items_recipe_id
  on public.meal_plan_items (recipe_id);
create index if not exists idx_meal_plan_items_food_id
  on public.meal_plan_items (food_id);
create index if not exists idx_meal_plan_items_plan_order
  on public.meal_plan_items (meal_plan_id, meal_slot, order_index);

-- ----------------------------------------------------------- grocery_lists --
create table if not exists public.grocery_lists (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  week_start date not null,
  status     text not null default 'open',
  created_at timestamptz not null default now(),
  constraint grocery_lists_status_check
    check (status in ('open', 'shopping', 'done', 'archived'))
);

comment on table public.grocery_lists is 'One shopping list per user per week.';

create unique index if not exists uq_grocery_lists_user_week
  on public.grocery_lists (user_id, week_start);
create index if not exists idx_grocery_lists_user_id
  on public.grocery_lists (user_id);
create index if not exists idx_grocery_lists_user_week_start
  on public.grocery_lists (user_id, week_start desc);

-- ----------------------------------------------------------- grocery_items --
create table if not exists public.grocery_items (
  id              uuid primary key default gen_random_uuid(),
  grocery_list_id uuid not null references public.grocery_lists (id) on delete cascade,
  food_id         uuid not null references public.foods (id) on delete restrict,
  quantity        numeric(10,2) not null check (quantity > 0),
  unit            text not null default 'g',
  -- Shop aisle grouping so the list is walkable: "Vegetables", "Dals", "Dairy".
  aisle           text,
  state           text not null default 'need',
  created_at      timestamptz not null default now(),
  constraint grocery_items_state_check
    check (state in ('need', 'have', 'bought'))
);

comment on table public.grocery_items is
  'A line on a shopping list. Ownership inherited from grocery_lists.';

create unique index if not exists uq_grocery_items_list_food
  on public.grocery_items (grocery_list_id, food_id);
create index if not exists idx_grocery_items_grocery_list_id
  on public.grocery_items (grocery_list_id);
create index if not exists idx_grocery_items_food_id
  on public.grocery_items (food_id);

-- ------------------------------------------------------------ pantry_items --
create table if not exists public.pantry_items (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  food_id    uuid not null references public.foods (id) on delete cascade,
  quantity   numeric(10,2) not null default 0 check (quantity >= 0),
  unit       text not null default 'g',
  updated_at timestamptz not null default now()
);

comment on table public.pantry_items is
  'What the user already has at home, so the grocery list does not re-buy it.';

create unique index if not exists uq_pantry_items_user_food
  on public.pantry_items (user_id, food_id);
create index if not exists idx_pantry_items_user_id
  on public.pantry_items (user_id);
create index if not exists idx_pantry_items_food_id
  on public.pantry_items (food_id);

drop trigger if exists trg_pantry_items_updated_at on public.pantry_items;
create trigger trg_pantry_items_updated_at
  before update on public.pantry_items
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------ alerts --
create table if not exists public.alerts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  alert_type    text not null,
  title         text not null,
  body          text,
  -- Human-readable schedule the phone turns into local alarms, e.g.
  -- 'RRULE:FREQ=DAILY;BYHOUR=8,11,14,17,20' or 'daily 07:30'.
  schedule_rule text,
  enabled       boolean not null default true,
  -- {"start": "22:00", "end": "07:00"} - never fire inside this window.
  quiet_hours   jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  constraint alerts_alert_type_check
    check (alert_type in ('hydration', 'meal', 'grocery', 'activity', 'sleep',
                          'nutrition', 'report_followup', 'weekly_summary',
                          'escalation')),
  constraint alerts_quiet_hours_is_object
    check (jsonb_typeof(quiet_hours) = 'object')
);

comment on table public.alerts is
  'Alert definitions. The phone schedules these locally (AlarmManager), so they '
  'fire with the app closed and with no internet.';

create index if not exists idx_alerts_user_id
  on public.alerts (user_id);
create index if not exists idx_alerts_user_enabled
  on public.alerts (user_id, alert_type) where enabled;

-- -------------------------------------------------------- alert_deliveries --
create table if not exists public.alert_deliveries (
  id          uuid primary key default gen_random_uuid(),
  alert_id    uuid not null references public.alerts (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  fired_at    timestamptz not null default now(),
  opened_at   timestamptz,
  actioned_at timestamptz,
  action      text
);

comment on table public.alert_deliveries is
  'Did the nudge fire, did they open it, did they act. Feeds the weekly summary.';

create index if not exists idx_alert_deliveries_alert_id
  on public.alert_deliveries (alert_id);
create index if not exists idx_alert_deliveries_user_id
  on public.alert_deliveries (user_id);
create index if not exists idx_alert_deliveries_user_fired_at
  on public.alert_deliveries (user_id, fired_at desc);
