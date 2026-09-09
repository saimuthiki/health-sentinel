-- ============================================================================
-- 203_rda_targets.sql
-- Energy is stored as 'kcal' to match foods.per_100g. One spelling across the
-- whole system, so gap arithmetic cannot silently miss it.
-- HealthPulse seed - daily nutrient targets for Indian adults
--
-- Run AFTER the migrations. Safe to run more than once.
--
-- Source for every row: Indian Council of Medical Research - National Institute
-- of Nutrition (ICMR-NIN). "Nutrient Requirements for Indians: Recommended
-- Dietary Allowances (RDA) and Estimated Average Requirements (EAR)", 2020.
-- Reference adult man 65 kg, reference adult woman 55 kg.
--
-- ###########################################################################
-- #  Same rule as the reference ranges: cite or omit.                       #
-- #  Only nutrients whose ICMR-NIN 2020 value could be stated with          #
-- #  confidence are seeded. Fibre, vitamin A, vitamin C, magnesium, iodine, #
-- #  selenium, the pregnancy and lactation increments, the 60+ adjustments  #
-- #  and every child/adolescent band are LEFT OUT and listed in             #
-- #  db/seed/GAPS.md for a dietitian to fill in from the printed table.     #
-- ###########################################################################
--
-- HOW THE PLANNER USES THIS (docs/04-ai-pipeline.md stage 6, "GAPS" block)
--   Pick the row matching the user's sex, age and activity_level; where
--   activity_level = 'any' the target does not vary with activity. Compare the
--   target with what the user actually ate (food_logs joined to foods) to get
--   "vitamin D 78% below target".
--
-- ACTIVITY LEVELS are ICMR-NIN's own three groups and must match
--   health_profiles.activity_level exactly: sedentary | moderate | heavy.
--
-- NUTRIENT KEYS match the keys used inside foods.per_100g.
-- ============================================================================

insert into public.rda_targets
  (nutrient, sex, age_min, age_max, activity_level, amount, unit, source, source_citation)
values

-- ------------------------------------------------------------------ energy --
('kcal',        'male',   19, 59, 'sedentary', 2110, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult man (65 kg), sedentary work, 2110 kcal/day.'),
('kcal',        'male',   19, 59, 'moderate',  2710, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult man (65 kg), moderate work, 2710 kcal/day.'),
('kcal',        'male',   19, 59, 'heavy',     3470, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult man (65 kg), heavy work, 3470 kcal/day.'),
('kcal',        'female', 19, 59, 'sedentary', 1660, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult woman (55 kg), sedentary work, 1660 kcal/day.'),
('kcal',        'female', 19, 59, 'moderate',  2130, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult woman (55 kg), moderate work, 2130 kcal/day.'),
('kcal',        'female', 19, 59, 'heavy',     2720, 'kcal', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: reference adult woman (55 kg), heavy work, 2720 kcal/day.'),

-- ----------------------------------------------------------------- protein --
-- Protein requirement is set per kg of body weight (0.83 g/kg/day), not by
-- activity level, so activity_level is 'any'.
('protein_g', 'male',   19, 59, 'any', 54, 'g', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for protein, reference adult man (65 kg), 54 g/day, derived from 0.83 g/kg body weight/day.'),
('protein_g', 'female', 19, 59, 'any', 46, 'g', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for protein, reference adult woman (55 kg), 46 g/day, derived from 0.83 g/kg body weight/day.'),

-- ----------------------------------------------------------------- calcium --
('calcium_mg', 'any', 19, 59, 'any', 1000, 'mg', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for calcium, adult men and women, 1000 mg/day.'),

-- -------------------------------------------------------------------- iron --
-- The higher figure for women reflects menstrual losses.
('iron_mg', 'male',   19, 59, 'any', 19, 'mg', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for iron, adult man, 19 mg/day.'),
('iron_mg', 'female', 19, 59, 'any', 29, 'mg', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for iron, adult woman of reproductive age, 29 mg/day.'),

-- -------------------------------------------------------------------- zinc --
('zinc_mg', 'male',   19, 59, 'any', 17, 'mg', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for zinc, adult man, 17 mg/day.'),
('zinc_mg', 'female', 19, 59, 'any', 13, 'mg', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for zinc, adult woman, 13 mg/day.'),

-- --------------------------------------------------------------- vitamin D --
('vitamin_d_ug', 'any', 19, 59, 'any', 15, 'ug', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for vitamin D, adults, 600 IU/day, which is 15 micrograms of cholecalciferol per day.'),

-- ------------------------------------------------------------- vitamin B12 --
('b12_ug', 'any', 19, 59, 'any', 2.2, 'ug', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for vitamin B12, adults, 2.2 micrograms/day.'),

-- ------------------------------------------------------------------ folate --
('folate_ug', 'any', 19, 59, 'any', 300, 'ug', 'ICMR-NIN 2020',
 'ICMR-NIN, Nutrient Requirements for Indians 2020: RDA for folate, adults, 300 micrograms/day.')

on conflict (nutrient, sex, age_min, age_max, activity_level) do nothing;


-- ============================================================================
-- CHECKS
-- ============================================================================

-- 1. How many targets were loaded.
select count(*) as rda_targets_loaded,
       count(distinct nutrient) as nutrients_covered
from public.rda_targets;

-- 2. Every row must have a citation. This must return 0 rows.
select id, nutrient
from public.rda_targets
where source_citation is null or length(btrim(source_citation)) = 0;

-- 3. What a moderately active 32-year-old man should be aiming for.
select nutrient, amount, unit
from public.rda_targets
where sex in ('male', 'any')
  and 32 between age_min and age_max
  and activity_level in ('moderate', 'any')
order by nutrient;
