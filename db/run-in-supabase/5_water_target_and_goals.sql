-- 5. A water target you set yourself, and one more kind of goal
--
-- Run this the same way as the first four files: Supabase -> SQL Editor -> New
-- query -> paste the whole file -> Run. It is safe to run twice; both statements
-- check before they change anything.
--
-- Until this runs, everything keeps working exactly as it does today. The only
-- thing that will not work is choosing your own daily water target, which will
-- fail on that screen with a message rather than quietly doing nothing.

-- 1. Somewhere to keep a water target you chose for yourself.
--
-- Null means you have not chosen one, and the app uses the figure it can cite a
-- source for. No bounds are set here on purpose: what counts as a safe amount is
-- a health judgement, and it is made in one place in the code where it can carry
-- its reasoning with it, rather than being half-enforced by the database as well.
alter table public.health_profiles
  add column if not exists hydration_target_override_ml integer;

comment on column public.health_profiles.hydration_target_override_ml is
  'A daily drinking-water target the person set for themselves, in millilitres. '
  'Null when they have not set one. Any safety bound belongs with the hydration '
  'rules, not here.';

-- 2. Let "eating better in general" be a goal you can pick.
--
-- The app offers eight kinds of goal and the database only ever allowed seven,
-- so picking that one was refused. This adds the missing kind.
alter table public.goals drop constraint if exists goals_goal_type_check;

alter table public.goals add constraint goals_goal_type_check
  check (goal_type in ('weight', 'hair', 'skin', 'energy', 'sleep', 'fitness',
                       'deficiency', 'diet_quality'));

-- Did it work? Both of these should say true.
select
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'health_profiles'
      and column_name = 'hydration_target_override_ml'
  ) as water_target_column_exists,
  exists (
    select 1 from pg_constraint
    where conname = 'goals_goal_type_check'
      and pg_get_constraintdef(oid) like '%diet_quality%'
  ) as diet_quality_goal_allowed;
