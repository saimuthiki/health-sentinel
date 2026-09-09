-- ============================================================================
-- 006_nutrition.sql
-- HealthPulse - foods, recipes, RDA targets, preferences, food logs
-- Target: PostgreSQL 15 (Supabase)
--
-- Depends on: 005_symptoms_goals_memory.sql
-- Safe to run more than once.
--
-- foods, recipes, recipe_items and rda_targets are SHARED REFERENCE data.
-- Every nutrient number the user ever sees is computed from foods.per_100g by
-- the backend - never taken from model free text (CLAUDE.md, hard rules).
-- ============================================================================

-- ------------------------------------------------------------------- foods --
create table if not exists public.foods (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  -- Hindi / Telugu / Tamil / regional name as commonly written in English script.
  name_local  text,
  food_group  text not null,
  -- Nutrients per 100 g edible portion. Keys used by the backend:
  --   kcal, protein_g, fat_g, carb_g, fibre_g, iron_mg, calcium_mg,
  --   vitamin_d_ug, b12_ug, folate_ug, zinc_mg, magnesium_mg, potassium_mg,
  --   sodium_mg, vitamin_c_mg, vitamin_a_ug
  -- A key that is ABSENT means "we do not have a trustworthy value", which is
  -- different from a value of 0. The backend must treat missing as unknown.
  per_100g    jsonb not null default '{}'::jsonb,
  -- Subset of: veg, non_veg, egg, vegan, jain, gluten_free, high_protein,
  -- high_fibre, high_iron, high_calcium, low_gi
  diet_flags  text[] not null default '{}',
  -- Subset of: milk, egg, peanut, tree_nut, sesame, soy, fish, shellfish,
  -- gluten, mustard
  allergens   text[] not null default '{}',
  region      text,
  -- 'PROVISIONAL' marks a starter row whose numbers have NOT been checked
  -- against an authoritative table yet. See db/seed/GAPS.md.
  source      text not null,
  source_id   text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint foods_source_check
    check (source in ('IFCT2017', 'USDA', 'PROVISIONAL')),
  constraint foods_per_100g_is_object
    check (jsonb_typeof(per_100g) = 'object'),
  constraint foods_name_not_blank check (length(btrim(name)) > 0)
);

comment on table public.foods is
  'Food composition reference. The single source of truth for nutrient numbers.';
comment on column public.foods.source is
  'IFCT2017 / USDA = verified import. PROVISIONAL = starter value, not yet checked.';

create unique index if not exists uq_foods_source_source_id
  on public.foods (source, source_id);
create index if not exists idx_foods_food_group
  on public.foods (food_group);
create index if not exists idx_foods_diet_flags
  on public.foods using gin (diet_flags);
create index if not exists idx_foods_allergens
  on public.foods using gin (allergens);
create index if not exists idx_foods_per_100g
  on public.foods using gin (per_100g);
create index if not exists idx_foods_name_trgm
  on public.foods using gin (name gin_trgm_ops);

drop trigger if exists trg_foods_updated_at on public.foods;
create trigger trg_foods_updated_at
  before update on public.foods
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------- recipes --
create table if not exists public.recipes (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  cuisine      text,
  -- Subset of: breakfast, mid_morning, lunch, snack, dinner, bedtime
  meal_slots   text[] not null default '{}',
  prep_minutes integer check (prep_minutes is null or prep_minutes >= 0),
  diet_flags   text[] not null default '{}',
  -- JSON array of plain-text steps: ["Soak the rice 4 hours", "Grind ..."]
  steps        jsonb not null default '[]'::jsonb,
  source       text,
  source_id    text,
  created_at   timestamptz not null default now(),
  constraint recipes_steps_is_array check (jsonb_typeof(steps) = 'array'),
  constraint recipes_name_not_blank check (length(btrim(name)) > 0)
);

comment on table public.recipes is
  'Shared recipe reference. Nutrients are never stored here - they are computed '
  'from recipe_items joined to foods.';

create unique index if not exists uq_recipes_source_source_id
  on public.recipes (source, source_id) where source is not null and source_id is not null;
create index if not exists idx_recipes_meal_slots
  on public.recipes using gin (meal_slots);
create index if not exists idx_recipes_diet_flags
  on public.recipes using gin (diet_flags);
create index if not exists idx_recipes_name_trgm
  on public.recipes using gin (name gin_trgm_ops);

-- ------------------------------------------------------------ recipe_items --
create table if not exists public.recipe_items (
  recipe_id uuid not null references public.recipes (id) on delete cascade,
  food_id   uuid not null references public.foods (id)   on delete restrict,
  grams     numeric(8,2) not null check (grams > 0),
  primary key (recipe_id, food_id)
);

comment on table public.recipe_items is
  'Ingredient lines of a recipe. Reference data: visible when the parent recipe '
  'is visible, writable only by the service role.';

create index if not exists idx_recipe_items_recipe_id
  on public.recipe_items (recipe_id);
create index if not exists idx_recipe_items_food_id
  on public.recipe_items (food_id);

-- ------------------------------------------------------------- rda_targets --
create table if not exists public.rda_targets (
  id              uuid primary key default gen_random_uuid(),
  -- Matches a key in foods.per_100g where possible: energy_kcal, protein_g,
  -- calcium_mg, iron_mg, zinc_mg, vitamin_d_ug, b12_ug, folate_ug ...
  nutrient        text not null,
  sex             text not null default 'any',
  age_min         integer not null default 0,
  age_max         integer not null default 120,
  -- 'any' for nutrients whose target does not vary with activity.
  activity_level  text not null default 'any',
  amount          numeric not null check (amount >= 0),
  unit            text not null,
  source          text not null,
  -- Full reference so a dietitian can check any number against the printed table.
  source_citation text not null,
  created_at      timestamptz not null default now(),
  constraint rda_targets_sex_check
    check (sex in ('male', 'female', 'any')),
  constraint rda_targets_activity_level_check
    check (activity_level in ('sedentary', 'moderate', 'heavy', 'any')),
  constraint rda_targets_source_check
    check (source in ('ICMR-NIN 2020')),
  constraint rda_targets_age_band_check
    check (age_min >= 0 and age_max >= age_min and age_max <= 120),
  constraint rda_targets_citation_not_blank
    check (length(btrim(source_citation)) > 0)
);

comment on table public.rda_targets is
  'Daily nutrient targets. Drives the GAPS block handed to the planner.';

create unique index if not exists uq_rda_targets_band
  on public.rda_targets (nutrient, sex, age_min, age_max, activity_level);
create index if not exists idx_rda_targets_lookup
  on public.rda_targets (sex, activity_level, nutrient);

-- ------------------------------------------------------- food_preferences --
create table if not exists public.food_preferences (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  food_id    uuid not null references public.foods (id) on delete cascade,
  stance     text not null default 'neutral',
  -- Rolling score from ratings, frequency, skips and recency. Pure arithmetic.
  score      numeric(5,2) not null default 0,
  updated_at timestamptz not null default now(),
  constraint food_preferences_stance_check
    check (stance in ('like', 'dislike', 'neutral', 'never'))
);

comment on table public.food_preferences is
  'Declared + observed preference per food. "never" is a hard exclusion.';

create unique index if not exists uq_food_preferences_user_food
  on public.food_preferences (user_id, food_id);
create index if not exists idx_food_preferences_user_id
  on public.food_preferences (user_id);
create index if not exists idx_food_preferences_food_id
  on public.food_preferences (food_id);

drop trigger if exists trg_food_preferences_updated_at on public.food_preferences;
create trigger trg_food_preferences_updated_at
  before update on public.food_preferences
  for each row execute function public.set_updated_at();

-- --------------------------------------------------------------- food_logs --
create table if not exists public.food_logs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  logged_at  timestamptz not null default now(),
  meal_slot  text,
  -- Nullable: a free-text or photo log may not resolve to a catalogue food.
  food_id    uuid references public.foods (id) on delete set null,
  free_text  text,
  image_path text,
  source     text not null default 'manual',
  created_at timestamptz not null default now(),
  constraint food_logs_source_check
    check (source in ('planned', 'chat', 'photo', 'manual')),
  constraint food_logs_meal_slot_check
    check (meal_slot is null or meal_slot in
      ('breakfast', 'mid_morning', 'lunch', 'snack', 'dinner', 'bedtime')),
  -- A log with nothing in it is not a log.
  constraint food_logs_has_content
    check (food_id is not null or length(btrim(coalesce(free_text, ''))) > 0
           or image_path is not null)
);

comment on table public.food_logs is
  'What the user actually ate. Feeds the observed-preference score.';

create index if not exists idx_food_logs_user_id
  on public.food_logs (user_id);
create index if not exists idx_food_logs_food_id
  on public.food_logs (food_id);
-- The diary query: "what did I eat this week".
create index if not exists idx_food_logs_user_logged_at
  on public.food_logs (user_id, logged_at desc);

-- ---------------------------------------------------------- food_feedback --
create table if not exists public.food_feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  food_log_id uuid not null references public.food_logs (id) on delete cascade,
  rating      smallint not null,
  note        text,
  created_at  timestamptz not null default now(),
  constraint food_feedback_rating_range check (rating between 1 and 5)
);

comment on table public.food_feedback is
  'Star rating on a logged meal. Drives "Dropped soya chunks - you rated it 1 star twice".';

create unique index if not exists uq_food_feedback_food_log
  on public.food_feedback (food_log_id);
create index if not exists idx_food_feedback_user_id
  on public.food_feedback (user_id);
create index if not exists idx_food_feedback_food_log_id
  on public.food_feedback (food_log_id);
