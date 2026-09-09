-- ============================================================================
-- 009_domain_alignment.sql
--
-- Closes the gaps between backend/app/domain/enums.py and the schema, found
-- while wiring the API layer. Written as a separate migration rather than an
-- edit to 002/003/007 because "create table if not exists" does not alter a
-- table that already exists -- so editing an earlier file would silently do
-- nothing for anyone who has already run it.
--
-- Safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. activity_level accepted only 3 of the 5 values ActivityLevel defines.
--
-- This was a real, user-visible defect: the repository had to fold `light` into
-- `sedentary` and `very_active` into `active`, so someone who set "very active"
-- during onboarding and reopened the app was shown "active". The nutrition
-- targets also key off activity, so the stored value silently changed what the
-- app recommended.
--
-- The RDA seed in 203_rda_targets.sql is keyed on the 3 ICMR-NIN bands, so
-- targets.py continues to map the 5 profile values onto those 3 bands. That
-- mapping is arithmetic, applied at lookup, and loses nothing stored.
-- ---------------------------------------------------------------------------
alter table public.health_profiles
  drop constraint if exists health_profiles_activity_level_check;

alter table public.health_profiles
  add constraint health_profiles_activity_level_check
  check (activity_level is null or activity_level in
         ('sedentary', 'light', 'moderate', 'active', 'very_active'));

-- ---------------------------------------------------------------------------
-- 2. meal_slot used 'snack'/'bedtime'; MealSlot defines 'evening_snack'.
-- Accept both spellings so existing rows stay valid, and let the enum's value
-- through. 'bedtime' has no enum member and is kept only so no row is orphaned.
-- ---------------------------------------------------------------------------
alter table public.meal_plan_items
  drop constraint if exists meal_plan_items_meal_slot_check;

alter table public.meal_plan_items
  add constraint meal_plan_items_meal_slot_check
  check (meal_slot in ('breakfast', 'mid_morning', 'lunch',
                       'evening_snack', 'snack', 'dinner', 'bedtime'));

-- ---------------------------------------------------------------------------
-- 3. A lab row that maps to no known biomarker had nowhere to record what the
-- report actually printed, or why it needs review. Without these the review
-- queue had to be rebuilt by re-running the normaliser over the stored raw
-- extraction every time. The whole point of needs_review is that a human
-- confirms an unrecognised value, and they cannot confirm what we did not keep.
-- ---------------------------------------------------------------------------
alter table public.lab_results
  add column if not exists printed_test_name text;

alter table public.lab_results
  add column if not exists review_reason text;

-- ---------------------------------------------------------------------------
-- 4. The daily hydration target belongs on the plan, not buried in a
-- health_events payload that has to be parsed back out.
-- ---------------------------------------------------------------------------
alter table public.meal_plans
  add column if not exists hydration_ml integer;

-- ---------------------------------------------------------------------------
-- 5. Sex 'prefer_not_to_say' is accepted by the schema but has no enum member,
-- so it reads back as Sex.OTHER. Left as is deliberately: the two mean
-- different things to a person, and collapsing them at write time would be the
-- same defect as (1). Recorded here so the next person sees it was a choice.
-- Adding a PREFER_NOT_TO_SAY member to Sex is the real fix, and it changes
-- reference-range selection, so it wants a deliberate pass.
-- ---------------------------------------------------------------------------

-- Check: all four alterations should report true.
select
  (select count(*) = 5 from unnest(array['sedentary','light','moderate','active','very_active']) v
     where pg_get_constraintdef(c.oid) like '%' || v || '%') as activity_ok,
  (select pg_get_constraintdef(c2.oid) like '%evening_snack%') as meal_slot_ok,
  (select count(*) = 2 from information_schema.columns
     where table_name = 'lab_results' and column_name in ('printed_test_name','review_reason')) as lab_cols_ok,
  (select count(*) = 1 from information_schema.columns
     where table_name = 'meal_plans' and column_name = 'hydration_ml') as hydration_ok
from pg_constraint c, pg_constraint c2
where c.conname = 'health_profiles_activity_level_check'
  and c2.conname = 'meal_plan_items_meal_slot_check';
