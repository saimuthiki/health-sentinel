-- ============================================================================
-- 202_reference_ranges.sql
-- HealthPulse seed - deterministic classification thresholds
--
-- Run AFTER 200_biomarkers.sql. Safe to run more than once.
--
-- ###########################################################################
-- #  SAFETY RULE FOR THIS FILE                                              #
-- #                                                                         #
-- #  Every row carries a source_citation naming the guideline the numbers   #
-- #  came from. No threshold in this file was invented, estimated or        #
-- #  averaged. Where a trustworthy published threshold could not be named,  #
-- #  THE ROW WAS LEFT OUT and the omission was written into                 #
-- #  db/seed/GAPS.md for a clinician to fill in.                            #
-- #                                                                         #
-- #  That is why some biomarkers below have a low but no high, or only a    #
-- #  critical value. A missing number means "we do not know", which the     #
-- #  classifier must treat as "cannot classify this direction" - never as   #
-- #  "normal".                                                              #
-- #                                                                         #
-- #  Do not add a row here without a citation. Do not change a number       #
-- #  without changing its citation.                                         #
-- ###########################################################################
--
-- HOW THE SIX NUMBERS ARE READ (docs/04-ai-pipeline.md stage 4)
--
--   The six thresholds always read in this order, ignoring nulls:
--     critical_low <= low <= borderline_low <= borderline_high <= high <= critical_high
--
--   Classification, first match wins:
--     value <  critical_low     -> critical_low
--     value <  low              -> low
--     value <  borderline_low   -> borderline_low
--     value >  critical_high    -> critical_high
--     value >  high             -> high
--     value >  borderline_high  -> borderline_high
--     otherwise                 -> normal
--
--   A null threshold means that step is skipped. It does NOT mean "normal".
--
-- UNITS
--   Every number below is in the biomarker's canonical_unit from
--   200_biomarkers.sql. Convert the lab's value BEFORE comparing.
--
-- MATCHING A ROW TO A USER
--   sex:        'male' / 'female' / 'any'. Prefer the sex-specific row.
--   age band:   age_min <= age <= age_max, in whole years.
--   pregnancy:  null = applies whatever the pregnancy status.
--               A true/false row overrides the null row for that user.
-- ============================================================================

insert into public.reference_ranges (
  biomarker_code, sex, age_min, age_max, pregnancy,
  critical_low, low, borderline_low, borderline_high, high, critical_high,
  source_citation)
values

-- ---------------------------------------------------------------------------
-- HAEMOGLOBIN - WHO anaemia thresholds
-- WHO. Haemoglobin concentrations for the diagnosis of anaemia and assessment
-- of severity. Vitamin and Mineral Nutrition Information System.
-- Geneva, World Health Organization, 2011 (WHO/NMH/NHD/MNM/11.1).
-- Bands used: severe / moderate / mild anaemia -> critical_low / low / borderline_low.
-- NOTE: docs/04-ai-pipeline.md uses Hb < 7 g/dL as the `urgent` escalation for
-- adults, which is stricter than WHO's severe-anaemia cut-off of 8 g/dL. Both
-- are kept: 8.0 classifies the value, 7.0 escalates. See db/seed/GAPS.md.
-- ---------------------------------------------------------------------------
('HB', 'male',   15, 120, null, 8.0, 11.0, 13.0, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), non-pregnant males 15+ years: normal >=13.0 g/dL; mild anaemia 11.0-12.9; moderate 8.0-10.9; severe <8.0 g/dL.'),

('HB', 'female', 15, 120, false, 8.0, 11.0, 12.0, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), non-pregnant females 15+ years: normal >=12.0 g/dL; mild anaemia 11.0-11.9; moderate 8.0-10.9; severe <8.0 g/dL.'),

('HB', 'female', 15, 120, true, 7.0, 10.0, 11.0, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), pregnant women: normal >=11.0 g/dL; mild anaemia 10.0-10.9; moderate 7.0-9.9; severe <7.0 g/dL.'),

('HB', 'any', 0, 4, null, 7.0, 10.0, 11.0, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), children 6-59 months: normal >=11.0 g/dL; mild anaemia 10.0-10.9; moderate 7.0-9.9; severe <7.0 g/dL.'),

('HB', 'any', 5, 11, null, 8.0, 11.0, 11.5, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), children 5-11 years: normal >=11.5 g/dL; mild anaemia 11.0-11.4; moderate 8.0-10.9; severe <8.0 g/dL.'),

('HB', 'any', 12, 14, null, 8.0, 11.0, 12.0, null, null, null,
 'WHO 2011 (WHO/NMH/NHD/MNM/11.1), children 12-14 years: normal >=12.0 g/dL; mild anaemia 11.0-11.9; moderate 8.0-10.9; severe <8.0 g/dL.'),

-- ---------------------------------------------------------------------------
-- GLYCAEMIC - American Diabetes Association
-- ---------------------------------------------------------------------------
('GLUCOSE_FASTING', 'any', 18, 120, null, 54, 70, null, 99, 125, 300,
 'American Diabetes Association, Standards of Care in Diabetes, Classification and Diagnosis: normal fasting plasma glucose <100 mg/dL; impaired fasting glucose 100-125 mg/dL; diabetes >=126 mg/dL. Hypoglycaemia: ADA/EASD Level 1 alert value <=70 mg/dL, Level 2 clinically significant <54 mg/dL. Critical high 300 mg/dL is the HealthPulse urgent red flag from docs/04-ai-pipeline.md stage 5.'),

('GLUCOSE_PP', 'any', 18, 120, null, null, null, null, 139, 199, null,
 'American Diabetes Association / WHO 75 g oral glucose tolerance test, 2-hour plasma glucose: normal <140 mg/dL; impaired glucose tolerance 140-199 mg/dL; diabetes >=200 mg/dL.'),

('GLUCOSE_RANDOM', 'any', 18, 120, null, null, null, null, null, 199, null,
 'American Diabetes Association, Standards of Care in Diabetes, Classification and Diagnosis: random plasma glucose >=200 mg/dL with classic symptoms of hyperglycaemia is diagnostic of diabetes.'),

('HBA1C', 'any', 18, 120, null, null, null, null, 5.6, 6.4, null,
 'American Diabetes Association, Standards of Care in Diabetes, Classification and Diagnosis: normal HbA1c <5.7%; prediabetes 5.7-6.4%; diabetes >=6.5%. docs/04-ai-pipeline.md escalates a first HbA1c >=6.5% to see_doctor_soon.'),

-- ---------------------------------------------------------------------------
-- LIPIDS - NCEP Adult Treatment Panel III
-- National Cholesterol Education Program (NCEP) Expert Panel on Detection,
-- Evaluation, and Treatment of High Blood Cholesterol in Adults (Adult
-- Treatment Panel III) Final Report. Circulation, 2002.
-- ---------------------------------------------------------------------------
('CHOL_TOTAL', 'any', 18, 120, null, null, null, null, 199, 239, null,
 'NCEP ATP III total cholesterol categories: desirable <200 mg/dL; borderline high 200-239 mg/dL; high >=240 mg/dL.'),

('LDL', 'any', 18, 120, null, null, null, null, 129, 159, 189,
 'NCEP ATP III LDL-cholesterol categories: optimal <100 mg/dL; near/above optimal 100-129; borderline high 130-159; high 160-189; very high >=190 mg/dL.'),

('HDL', 'male', 18, 120, null, null, 40, null, null, null, null,
 'NCEP ATP III: HDL-cholesterol <40 mg/dL is a categorical major risk factor for coronary heart disease in men.'),

('HDL', 'female', 18, 120, null, null, 50, null, null, null, null,
 'NCEP ATP III metabolic syndrome criteria: low HDL-cholesterol is <40 mg/dL in men and <50 mg/dL in women.'),

('TRIG', 'any', 18, 120, null, null, null, null, 149, 199, 499,
 'NCEP ATP III triglyceride categories: normal <150 mg/dL; borderline high 150-199; high 200-499; very high >=500 mg/dL (very high carries a risk of acute pancreatitis).'),

('NON_HDL', 'any', 18, 120, null, null, null, null, 129, 159, null,
 'NCEP ATP III: the non-HDL-cholesterol goal is the LDL-cholesterol goal plus 30 mg/dL, giving <130 mg/dL for moderate-risk adults and <160 mg/dL for lower-risk adults. This target is risk-stratified - see db/seed/GAPS.md.'),

-- ---------------------------------------------------------------------------
-- THYROID
-- ---------------------------------------------------------------------------
('TSH', 'any', 18, 120, null, null, 0.45, null, 4.5, 10.0, null,
 'American Thyroid Association guidelines for the treatment of hypothyroidism (Jonklaas et al., Thyroid 2014) and the ATA/AACE definition of subclinical disease: TSH above the upper reference limit of approximately 4.5 mIU/L with a normal free T4 is subclinical hypothyroidism; TSH >10 mIU/L is overt hypothyroidism warranting treatment; TSH below the lower reference limit of approximately 0.45 mIU/L indicates thyrotoxicosis. docs/04-ai-pipeline.md escalates TSH >10 to see_doctor_soon.'),

-- ---------------------------------------------------------------------------
-- LIVER
-- ---------------------------------------------------------------------------
('ALT', 'male', 18, 120, null, null, null, null, null, 33, null,
 'ACG Clinical Guideline: Evaluation of Abnormal Liver Chemistries (Kwo, Cohen, Lim; Am J Gastroenterol 2017): the true healthy upper limit of normal for ALT is 29-33 IU/L in males. The upper bound of that range is used here.'),

('ALT', 'female', 18, 120, null, null, null, null, null, 25, null,
 'ACG Clinical Guideline: Evaluation of Abnormal Liver Chemistries (Kwo, Cohen, Lim; Am J Gastroenterol 2017): the true healthy upper limit of normal for ALT is 19-25 IU/L in females. The upper bound of that range is used here.'),

-- ---------------------------------------------------------------------------
-- KIDNEY
-- ---------------------------------------------------------------------------
('EGFR', 'any', 18, 120, null, 15, 60, 90, null, null, null,
 'KDIGO 2012 Clinical Practice Guideline for the Evaluation and Management of Chronic Kidney Disease, GFR categories: G1 >=90; G2 60-89 (mildly decreased); G3a-G4 15-59 (moderately to severely decreased); G5 <15 mL/min/1.73m2 (kidney failure).'),

('URIC_ACID', 'any', 18, 120, null, null, null, null, 6.0, 6.8, null,
 'American College of Rheumatology Guideline for the Management of Gout (FitzGerald et al., Arthritis Care Res 2020) recommends a serum urate treatment target of <6 mg/dL. Hyperuricaemia is conventionally defined by the limit of urate solubility in serum, approximately 6.8 mg/dL.'),

-- ---------------------------------------------------------------------------
-- VITAMINS AND IRON
-- ---------------------------------------------------------------------------
('VITD_25OH', 'any', 18, 120, null, null, 20, 30, null, null, null,
 'Endocrine Society Clinical Practice Guideline, Evaluation, Treatment, and Prevention of Vitamin D Deficiency (Holick et al., J Clin Endocrinol Metab 2011): deficiency 25(OH)D <20 ng/mL; insufficiency 21-29 ng/mL; sufficiency >=30 ng/mL. The US Institute of Medicine (2011) uses a lower cut-off of 20 ng/mL for sufficiency - see db/seed/GAPS.md.'),

('VITB12', 'any', 18, 120, null, null, 200, 300, null, null, null,
 'British Committee for Standards in Haematology, Guidelines for the diagnosis and treatment of cobalamin and folate disorders (Devalia, Hamilton, Molloy; Br J Haematol 2014): serum cobalamin below approximately 200 ng/L (pg/mL) indicates deficiency; 200-300 ng/L is an indeterminate/borderline zone requiring a second-line test such as methylmalonic acid.'),

('FOLATE', 'any', 18, 120, null, null, 3.0, null, null, null, null,
 'British Committee for Standards in Haematology, Guidelines for the diagnosis and treatment of cobalamin and folate disorders (Devalia, Hamilton, Molloy; Br J Haematol 2014): serum folate below approximately 7 nmol/L (3 ug/L, i.e. 3 ng/mL) indicates folate deficiency.'),

('FERRITIN', 'any', 18, 120, null, null, 15, 30, null, null, null,
 'WHO guideline on use of ferritin concentrations to assess iron status in individuals and populations (2020): ferritin <15 ug/L indicates iron deficiency in adults. British Society of Gastroenterology guidelines for the management of iron deficiency anaemia (Snook et al., Gut 2021): ferritin <30 ug/L confirms iron deficiency. ng/mL is numerically equal to ug/L.'),

-- ---------------------------------------------------------------------------
-- CRITICAL-VALUE-ONLY ROWS
-- These biomarkers have no seeded normal interval because a citable,
-- assay-independent one could not be named. Only the red-flag threshold is
-- stored, so the app can still escalate. See db/seed/GAPS.md.
-- ---------------------------------------------------------------------------
('POTASSIUM', 'any', 18, 120, null, 2.5, null, null, null, null, 6.0,
 'HealthPulse red-flag thresholds, docs/04-ai-pipeline.md stage 5: serum potassium <2.5 or >6.0 mmol/L is an urgent escalation. The normal reference interval for potassium is assay- and laboratory-dependent and is deliberately NOT seeded - see db/seed/GAPS.md.'),

('PLT', 'any', 18, 120, null, 50, null, null, null, null, null,
 'HealthPulse red-flag thresholds, docs/04-ai-pipeline.md stage 5: platelets <50 x10^3/uL is an urgent escalation. This agrees with NCI CTCAE v5.0, where a platelet count <50.0 x10^9/L is grade 3 or worse thrombocytopenia. The normal platelet interval is laboratory-dependent and is deliberately NOT seeded - see db/seed/GAPS.md.'),

-- ---------------------------------------------------------------------------
-- INFLAMMATION
-- ---------------------------------------------------------------------------
('CRP_HS', 'any', 18, 120, null, null, null, null, 1.0, 3.0, null,
 'AHA/CDC Scientific Statement, Markers of Inflammation and Cardiovascular Disease (Pearson et al., Circulation 2003): hs-CRP <1.0 mg/L low relative cardiovascular risk; 1.0-3.0 mg/L average risk; >3.0 mg/L high risk.')

on conflict (biomarker_code, sex, age_min, age_max, pregnancy) do nothing;


-- ============================================================================
-- CHECKS
-- ============================================================================

-- 1. How many ranges were loaded, and for how many biomarkers.
select count(*) as ranges_loaded,
       count(distinct biomarker_code) as biomarkers_covered
from public.reference_ranges;

-- 2. Every row must have a citation. This must return 0 rows.
select id, biomarker_code
from public.reference_ranges
where source_citation is null or length(btrim(source_citation)) = 0;

-- 3. Which seeded biomarkers still have NO range at all. These are the gaps a
--    clinician has to fill; they are listed in db/seed/GAPS.md.
select b.code, b.display_name, b.category
from public.biomarkers b
left join public.reference_ranges r on r.biomarker_code = b.code
where r.id is null
order by b.category, b.code;
