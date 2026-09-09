-- ============================================================================
-- 200_biomarkers.sql
-- HealthPulse seed - canonical biomarker catalogue
--
-- Run AFTER the migrations and the policy files.
-- Safe to run more than once (ON CONFLICT DO NOTHING).
--
-- 82 biomarkers covering the panels an Indian lab normally prints:
-- CBC, lipid, thyroid, liver (LFT), kidney (KFT/RFT), glycaemic (fasting / PP /
-- HbA1c), vitamins (D, B12, folate, A), iron studies (ferritin, iron, TIBC,
-- transferrin saturation), minerals and electrolytes, and a short tail of
-- commonly ordered extras.
--
-- canonical_unit is the unit EVERY lab_results.value must be converted into
-- before it is compared with reference_ranges. Units are written in plain ASCII
-- (ug, uIU, umol) so nothing breaks when this file is pasted into a browser.
--
-- higher_is_worse:  true  = a high value is the concerning direction
--                   false = a low value is the concerning direction
--                   null  = both directions matter
-- ============================================================================

insert into public.biomarkers (code, display_name, category, canonical_unit, higher_is_worse)
values
  -- haematology
  ('HB', 'Haemoglobin', 'haematology', 'g/dL', false),
  ('RBC', 'Red Blood Cell Count', 'haematology', 'million/uL', null),
  ('WBC', 'Total Leucocyte Count (WBC)', 'haematology', '10^3/uL', null),
  ('PLT', 'Platelet Count', 'haematology', '10^3/uL', false),
  ('PCV', 'Packed Cell Volume (Haematocrit)', 'haematology', '%', null),
  ('MCV', 'Mean Corpuscular Volume', 'haematology', 'fL', null),
  ('MCH', 'Mean Corpuscular Haemoglobin', 'haematology', 'pg', null),
  ('MCHC', 'Mean Corpuscular Haemoglobin Concentration', 'haematology', 'g/dL', null),
  ('RDW', 'Red Cell Distribution Width', 'haematology', '%', true),
  ('NEUT_PCT', 'Neutrophils', 'haematology', '%', null),
  -- Absolute neutrophil count, not the percentage. The neutropenia red-flag rule
  -- in backend/app/rules/red_flags.py fires below 500 cells/uL and can only ever
  -- fire on an absolute count, so this code must exist for that rule to be live.
  ('NEUTROPHILS_ABS', 'Absolute Neutrophil Count', 'haematology', 'cells/uL', false),
  ('LYMPH_PCT', 'Lymphocytes', 'haematology', '%', null),
  ('MONO_PCT', 'Monocytes', 'haematology', '%', null),
  ('EOS_PCT', 'Eosinophils', 'haematology', '%', true),
  ('BASO_PCT', 'Basophils', 'haematology', '%', null),
  ('ESR', 'Erythrocyte Sedimentation Rate', 'haematology', 'mm/hr', true),
  ('RETIC_PCT', 'Reticulocyte Count', 'haematology', '%', null),
  -- lipid
  ('CHOL_TOTAL', 'Total Cholesterol', 'lipid', 'mg/dL', true),
  ('HDL', 'HDL Cholesterol', 'lipid', 'mg/dL', false),
  ('LDL', 'LDL Cholesterol', 'lipid', 'mg/dL', true),
  ('VLDL', 'VLDL Cholesterol', 'lipid', 'mg/dL', true),
  ('TRIG', 'Triglycerides', 'lipid', 'mg/dL', true),
  ('NON_HDL', 'Non-HDL Cholesterol', 'lipid', 'mg/dL', true),
  ('CHOL_HDL_RATIO', 'Total Cholesterol / HDL Ratio', 'lipid', 'ratio', true),
  ('LDL_HDL_RATIO', 'LDL / HDL Ratio', 'lipid', 'ratio', true),
  ('LIPOPROTEIN_A', 'Lipoprotein (a)', 'lipid', 'mg/dL', true),
  ('APO_B', 'Apolipoprotein B', 'lipid', 'mg/dL', true),
  -- thyroid
  ('TSH', 'Thyroid Stimulating Hormone', 'thyroid', 'uIU/mL', null),
  ('FT3', 'Free T3', 'thyroid', 'pg/mL', null),
  ('FT4', 'Free T4', 'thyroid', 'ng/dL', null),
  ('T3_TOTAL', 'Total T3', 'thyroid', 'ng/dL', null),
  ('T4_TOTAL', 'Total T4', 'thyroid', 'ug/dL', null),
  ('ANTI_TPO', 'Anti-Thyroid Peroxidase Antibody', 'thyroid', 'IU/mL', true),
  -- liver
  ('BILI_TOTAL', 'Total Bilirubin', 'liver', 'mg/dL', true),
  ('BILI_DIRECT', 'Direct Bilirubin', 'liver', 'mg/dL', true),
  ('BILI_INDIRECT', 'Indirect Bilirubin', 'liver', 'mg/dL', true),
  ('ALT', 'SGPT (ALT)', 'liver', 'U/L', true),
  ('AST', 'SGOT (AST)', 'liver', 'U/L', true),
  ('ALP', 'Alkaline Phosphatase', 'liver', 'U/L', true),
  ('GGT', 'Gamma GT', 'liver', 'U/L', true),
  ('PROTEIN_TOTAL', 'Total Protein', 'liver', 'g/dL', null),
  ('ALBUMIN', 'Albumin', 'liver', 'g/dL', false),
  ('GLOBULIN', 'Globulin', 'liver', 'g/dL', null),
  ('AG_RATIO', 'Albumin / Globulin Ratio', 'liver', 'ratio', false),
  -- kidney
  ('UREA', 'Blood Urea', 'kidney', 'mg/dL', true),
  ('BUN', 'Blood Urea Nitrogen', 'kidney', 'mg/dL', true),
  ('CREATININE', 'Serum Creatinine', 'kidney', 'mg/dL', true),
  ('EGFR', 'Estimated GFR', 'kidney', 'mL/min/1.73m2', false),
  ('URIC_ACID', 'Uric Acid', 'kidney', 'mg/dL', true),
  ('UACR', 'Urine Albumin / Creatinine Ratio', 'kidney', 'mg/g', true),
  -- glycaemic
  ('GLUCOSE_FASTING', 'Fasting Blood Glucose', 'glycaemic', 'mg/dL', true),
  ('GLUCOSE_PP', 'Post Prandial Blood Glucose (2 hr)', 'glycaemic', 'mg/dL', true),
  ('GLUCOSE_RANDOM', 'Random Blood Glucose', 'glycaemic', 'mg/dL', true),
  ('HBA1C', 'Glycated Haemoglobin (HbA1c)', 'glycaemic', '%', true),
  ('INSULIN_FASTING', 'Fasting Insulin', 'glycaemic', 'uIU/mL', true),
  -- vitamin
  ('VITD_25OH', 'Vitamin D (25-OH)', 'vitamin', 'ng/mL', false),
  ('VITB12', 'Vitamin B12 (Cobalamin)', 'vitamin', 'pg/mL', false),
  ('FOLATE', 'Folate (Folic Acid)', 'vitamin', 'ng/mL', false),
  ('VITA', 'Vitamin A (Retinol)', 'vitamin', 'ug/dL', false),
  -- iron_studies
  ('FERRITIN', 'Ferritin', 'iron_studies', 'ng/mL', false),
  ('IRON', 'Serum Iron', 'iron_studies', 'ug/dL', false),
  ('TIBC', 'Total Iron Binding Capacity', 'iron_studies', 'ug/dL', null),
  ('UIBC', 'Unsaturated Iron Binding Capacity', 'iron_studies', 'ug/dL', null),
  ('TRANSFERRIN_SAT', 'Transferrin Saturation', 'iron_studies', '%', false),
  -- mineral
  ('CALCIUM', 'Serum Calcium (Total)', 'mineral', 'mg/dL', null),
  ('CALCIUM_IONIZED', 'Ionised Calcium', 'mineral', 'mg/dL', null),
  ('PHOSPHORUS', 'Serum Phosphorus', 'mineral', 'mg/dL', null),
  ('MAGNESIUM', 'Serum Magnesium', 'mineral', 'mg/dL', null),
  -- Referenced by the biomarker-to-nutrient map in backend/app/nutrition/gaps.py.
  ('ZINC', 'Serum Zinc', 'mineral', 'ug/dL', false),
  -- electrolyte
  ('SODIUM', 'Serum Sodium', 'electrolyte', 'mmol/L', null),
  ('POTASSIUM', 'Serum Potassium', 'electrolyte', 'mmol/L', null),
  ('CHLORIDE', 'Serum Chloride', 'electrolyte', 'mmol/L', null),
  ('BICARBONATE', 'Serum Bicarbonate', 'electrolyte', 'mmol/L', null),
  -- inflammation
  ('CRP_HS', 'High Sensitivity C-Reactive Protein', 'inflammation', 'mg/L', true),
  -- metabolic
  ('HOMOCYSTEINE', 'Homocysteine', 'metabolic', 'umol/L', true),
  -- tumour_marker
  ('PSA', 'Prostate Specific Antigen (Total)', 'tumour_marker', 'ng/mL', true),
  -- muscle
  ('CPK', 'Creatine Phosphokinase', 'muscle', 'U/L', true),
  -- pancreas
  ('AMYLASE', 'Serum Amylase', 'pancreas', 'U/L', true),
  ('LIPASE', 'Serum Lipase', 'pancreas', 'U/L', true),
  -- metabolic
  ('LDH', 'Lactate Dehydrogenase', 'metabolic', 'U/L', true),
  -- hormone
  ('CORTISOL_AM', 'Serum Cortisol (Morning)', 'hormone', 'ug/dL', null),
  ('PTH', 'Parathyroid Hormone', 'hormone', 'pg/mL', null),
  ('TESTOSTERONE_TOTAL', 'Total Testosterone', 'hormone', 'ng/dL', null),
  ('PROLACTIN', 'Prolactin', 'hormone', 'ng/mL', true)
on conflict (code) do nothing;

-- Check: this must print 84.
select count(*) as biomarkers_loaded from public.biomarkers;
