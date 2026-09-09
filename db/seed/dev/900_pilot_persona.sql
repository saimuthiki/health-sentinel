-- ===========================================================================
-- 900_pilot_persona.sql   -- DEVELOPMENT ONLY. Never run this in production.
--
-- A realistic pilot persona for exercising the planner, the preference engine
-- and the alert scheduler end to end.
--
-- The numbers below are modelled on the project owner's own parameters so the
-- output is realistic to review, but the persona is deliberately anonymous: no
-- real name, no real email, no real report values. Personal health data does
-- not belong in git history, least of all in a repository that may become
-- public when the app is published.
--
-- The owner's real profile goes into the running app through onboarding, where
-- it lands in Postgres behind row level security -- which is the whole point of
-- the architecture.
--
-- Usage: create a user in Supabase Auth first, then replace :user_id below.
-- ===========================================================================

\set user_id '00000000-0000-0000-0000-000000000001'

insert into public.profiles (user_id, display_name, locale, timezone)
values (:'user_id', 'Pilot User', 'en-IN', 'Asia/Kolkata')
on conflict (user_id) do nothing;

insert into public.health_profiles (
  user_id, dob, sex, height_cm, weight_kg, activity_level, diet_type,
  cuisine_pref, city, wake_time, sleep_time, meal_times, conditions, pregnancy
) values (
  :'user_id',
  date '2001-01-15',            -- 25 years old
  'male',
  170,                          -- 5 ft 7 in
  82,                           -- BMI about 28.4
  'moderate',                   -- daily badminton or a run, around 10k steps
  'non_veg',                    -- eats both vegetarian and non-vegetarian
  array['south_indian', 'telugu', 'north_indian'],
  'Hyderabad',
  time '07:00',
  time '23:00',                 -- around 8 hours
  '{"breakfast": "09:00", "lunch": "13:30", "dinner": "21:00"}'::jsonb,
  array[]::text[],              -- no diagnosed conditions
  false
) on conflict (user_id) do nothing;

-- Goals, in the owner's own words, highest priority first.
insert into public.goals (user_id, goal_type, title, priority, status) values
  (:'user_id', 'weight',  'Lose weight',            1, 'active'),
  (:'user_id', 'skin',    'Improve skin glow',      2, 'active'),
  (:'user_id', 'hair',    'Support hair growth',    3, 'active')
on conflict do nothing;

-- Declared food stances. The observed layer (food_logs, food_feedback) refines
-- these over time; these are only the starting point.
--
-- Matched by pattern, not exact name, because the foods table uses precise
-- descriptive names ("Pigeon pea, split (toor / arhar dal)") rather than the
-- casual ones a person uses. That mismatch is itself a finding: the chat and
-- onboarding layers will need the same fuzzy mapping to turn "dal" into a row.
insert into public.food_preferences (user_id, food_id, stance, score)
select :'user_id', f.id, 'like', 1.0
from public.foods f
where f.name ~* 'chicken|oats|ragi|finger millet'
   or f.name ~* 'toor|masoor|moong|chana|urad'          -- "dal and lentils"
   or f.name ~* '^(cow|toned|buffalo|skimmed) milk$'
on conflict do nothing;

-- Two of the owner's named favourites are DISHES, not foods: sambar and
-- biryani. They belong in `recipes`, which is empty by design (see
-- db/seed/GAPS.md item 6). Until the recipe table is seeded, the planner cannot
-- suggest either, which would make its very first suggestion to this user miss
-- two of the things they actually eat. Seeding real South Indian and Telugu
-- recipes is therefore a prerequisite for the meal planner, not a nice-to-have.
--
-- "Soya chunks" is likewise absent: the table has "Soyabean, dry", which is a
-- different food with different nutrients. Mapping one to the other would put a
-- wrong protein number in front of a user, so it is left unmapped.
--
-- No dislikes are seeded. The owner listed foods they eat but named none they
-- refuse. An empty dislike list is honest; inventing dislikes would teach the
-- planner something untrue about a real person on day one.
