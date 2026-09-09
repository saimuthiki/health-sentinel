-- ============================================================================
-- 201_biomarker_synonyms.sql
-- HealthPulse seed - printed lab test name -> canonical biomarker code
--
-- Run AFTER 200_biomarkers.sql. Safe to run more than once.
--
-- 353 synonyms. These are the names as they appear on Indian lab reports
-- (Thyrocare / Dr Lal PathLabs / Apollo / Metropolis style naming), including
-- the British and American spellings, the "S." and "Serum" prefixes, the
-- bracketed abbreviations and the hyphenated variants that all mean the same
-- test.
--
-- IMPORTANT - how the lookup works (docs/04-ai-pipeline.md stage 3):
--   The backend must LOWERCASE the printed name and squash runs of whitespace
--   to a single space before looking it up here. Every key below is already in
--   that form. An exact hit maps the row. A miss is stored with
--   needs_review = true and shown to the user - we never silently guess.
--
-- The `source` column says how sure we are of the string, not which company
-- printed it:
--   'common'     - standard clinical naming, used by essentially every lab
--   'indian_lab' - a variant characteristic of Indian lab report layouts
-- Attributing an exact string to a named laboratory would need real reports to
-- check against; see db/seed/GAPS.md.
-- ============================================================================

insert into public.biomarker_synonyms (synonym, biomarker_code, source)
values
  -- HB
  ('haemoglobin', 'HB', 'common'),
  ('hemoglobin', 'HB', 'common'),
  ('hb', 'HB', 'common'),
  ('hgb', 'HB', 'common'),
  ('haemoglobin (hb)', 'HB', 'common'),
  ('hemoglobin (hb)', 'HB', 'common'),
  ('haemoglobin - hb', 'HB', 'common'),
  ('blood haemoglobin', 'HB', 'common'),
  ('hemoglobin, blood', 'HB', 'common'),
  -- RBC
  ('rbc count', 'RBC', 'common'),
  ('red blood cell count', 'RBC', 'common'),
  ('total rbc count', 'RBC', 'common'),
  ('rbc', 'RBC', 'common'),
  ('erythrocyte count', 'RBC', 'common'),
  ('total rbc', 'RBC', 'common'),
  -- WBC
  ('wbc count', 'WBC', 'common'),
  ('total leucocyte count', 'WBC', 'common'),
  ('total leukocyte count', 'WBC', 'common'),
  ('tlc', 'WBC', 'indian_lab'),
  ('total wbc count', 'WBC', 'common'),
  ('white blood cell count', 'WBC', 'common'),
  ('leucocyte count', 'WBC', 'common'),
  ('total leucocyte count (tlc)', 'WBC', 'indian_lab'),
  ('wbc', 'WBC', 'common'),
  -- PLT
  ('platelet count', 'PLT', 'common'),
  ('platelets', 'PLT', 'common'),
  ('plt', 'PLT', 'common'),
  ('platelet count (plt)', 'PLT', 'common'),
  ('total platelet count', 'PLT', 'common'),
  -- PCV
  ('pcv', 'PCV', 'common'),
  ('packed cell volume', 'PCV', 'common'),
  ('packed cell volume (pcv)', 'PCV', 'common'),
  ('haematocrit', 'PCV', 'common'),
  ('hematocrit', 'PCV', 'common'),
  ('hct', 'PCV', 'common'),
  -- MCV
  ('mcv', 'MCV', 'common'),
  ('mean corpuscular volume', 'MCV', 'common'),
  ('mean cell volume', 'MCV', 'common'),
  -- MCH
  ('mch', 'MCH', 'common'),
  ('mean corpuscular haemoglobin', 'MCH', 'common'),
  ('mean corpuscular hemoglobin', 'MCH', 'common'),
  -- MCHC
  ('mchc', 'MCHC', 'common'),
  ('mean corpuscular haemoglobin concentration', 'MCHC', 'common'),
  ('mean corpuscular hemoglobin concentration', 'MCHC', 'common'),
  -- RDW
  ('rdw', 'RDW', 'common'),
  ('red cell distribution width', 'RDW', 'common'),
  ('rdw-cv', 'RDW', 'common'),
  ('rdw cv', 'RDW', 'common'),
  -- NEUT_PCT
  ('neutrophils', 'NEUT_PCT', 'common'),
  ('neutrophil', 'NEUT_PCT', 'common'),
  ('neutrophils %', 'NEUT_PCT', 'common'),
  ('segmented neutrophils', 'NEUT_PCT', 'common'),
  ('polymorphs', 'NEUT_PCT', 'indian_lab'),
  -- LYMPH_PCT
  ('lymphocytes', 'LYMPH_PCT', 'common'),
  ('lymphocyte', 'LYMPH_PCT', 'common'),
  ('lymphocytes %', 'LYMPH_PCT', 'common'),
  -- MONO_PCT
  ('monocytes', 'MONO_PCT', 'common'),
  ('monocyte', 'MONO_PCT', 'common'),
  ('monocytes %', 'MONO_PCT', 'common'),
  -- EOS_PCT
  ('eosinophils', 'EOS_PCT', 'common'),
  ('eosinophil', 'EOS_PCT', 'common'),
  ('eosinophils %', 'EOS_PCT', 'common'),
  -- BASO_PCT
  ('basophils', 'BASO_PCT', 'common'),
  ('basophil', 'BASO_PCT', 'common'),
  ('basophils %', 'BASO_PCT', 'common'),
  -- ESR
  ('esr', 'ESR', 'common'),
  ('erythrocyte sedimentation rate', 'ESR', 'common'),
  ('esr (westergren)', 'ESR', 'indian_lab'),
  ('erythrocyte sedimentation rate (esr)', 'ESR', 'common'),
  ('sedimentation rate', 'ESR', 'common'),
  -- RETIC_PCT
  ('reticulocyte count', 'RETIC_PCT', 'common'),
  ('retic count', 'RETIC_PCT', 'common'),
  ('reticulocytes', 'RETIC_PCT', 'common'),
  -- CHOL_TOTAL
  ('total cholesterol', 'CHOL_TOTAL', 'common'),
  ('cholesterol total', 'CHOL_TOTAL', 'common'),
  ('cholesterol - total', 'CHOL_TOTAL', 'common'),
  ('serum cholesterol', 'CHOL_TOTAL', 'common'),
  ('cholesterol', 'CHOL_TOTAL', 'common'),
  ('s. cholesterol', 'CHOL_TOTAL', 'indian_lab'),
  -- HDL
  ('hdl cholesterol', 'HDL', 'common'),
  ('hdl', 'HDL', 'common'),
  ('hdl - cholesterol', 'HDL', 'common'),
  ('high density lipoprotein', 'HDL', 'common'),
  ('cholesterol hdl', 'HDL', 'common'),
  ('hdl cholesterol - direct', 'HDL', 'common'),
  -- LDL
  ('ldl cholesterol', 'LDL', 'common'),
  ('ldl', 'LDL', 'common'),
  ('ldl - cholesterol', 'LDL', 'common'),
  ('low density lipoprotein', 'LDL', 'common'),
  ('cholesterol ldl', 'LDL', 'common'),
  ('ldl cholesterol - calculated', 'LDL', 'common'),
  -- VLDL
  ('vldl cholesterol', 'VLDL', 'common'),
  ('vldl', 'VLDL', 'common'),
  ('very low density lipoprotein', 'VLDL', 'common'),
  -- TRIG
  ('triglycerides', 'TRIG', 'common'),
  ('triglyceride', 'TRIG', 'common'),
  ('serum triglycerides', 'TRIG', 'common'),
  ('s. triglycerides', 'TRIG', 'indian_lab'),
  ('tg', 'TRIG', 'common'),
  -- NON_HDL
  ('non hdl cholesterol', 'NON_HDL', 'common'),
  ('non-hdl cholesterol', 'NON_HDL', 'common'),
  -- CHOL_HDL_RATIO
  ('total cholesterol / hdl ratio', 'CHOL_HDL_RATIO', 'common'),
  ('chol/hdl ratio', 'CHOL_HDL_RATIO', 'common'),
  ('tc/hdl ratio', 'CHOL_HDL_RATIO', 'common'),
  ('cholesterol / hdl ratio', 'CHOL_HDL_RATIO', 'common'),
  -- LDL_HDL_RATIO
  ('ldl / hdl ratio', 'LDL_HDL_RATIO', 'common'),
  ('ldl/hdl ratio', 'LDL_HDL_RATIO', 'common'),
  -- LIPOPROTEIN_A
  ('lipoprotein (a)', 'LIPOPROTEIN_A', 'common'),
  ('lp(a)', 'LIPOPROTEIN_A', 'common'),
  ('lipoprotein a', 'LIPOPROTEIN_A', 'common'),
  -- APO_B
  ('apolipoprotein b', 'APO_B', 'common'),
  ('apo b', 'APO_B', 'common'),
  ('apo-b', 'APO_B', 'common'),
  -- TSH
  ('tsh', 'TSH', 'common'),
  ('thyroid stimulating hormone', 'TSH', 'common'),
  ('tsh - ultrasensitive', 'TSH', 'indian_lab'),
  ('thyroid stimulating hormone (tsh)', 'TSH', 'common'),
  ('s. tsh', 'TSH', 'indian_lab'),
  ('tsh ultra sensitive', 'TSH', 'indian_lab'),
  -- FT3
  ('free t3', 'FT3', 'common'),
  ('ft3', 'FT3', 'common'),
  ('free tri-iodothyronine', 'FT3', 'common'),
  ('free triiodothyronine', 'FT3', 'common'),
  -- FT4
  ('free t4', 'FT4', 'common'),
  ('ft4', 'FT4', 'common'),
  ('free thyroxine', 'FT4', 'common'),
  -- T3_TOTAL
  ('total t3', 'T3_TOTAL', 'common'),
  ('t3', 'T3_TOTAL', 'common'),
  ('triiodothyronine', 'T3_TOTAL', 'common'),
  ('tri-iodothyronine (t3)', 'T3_TOTAL', 'common'),
  ('t3 - total', 'T3_TOTAL', 'common'),
  -- T4_TOTAL
  ('total t4', 'T4_TOTAL', 'common'),
  ('t4', 'T4_TOTAL', 'common'),
  ('thyroxine', 'T4_TOTAL', 'common'),
  ('thyroxine (t4)', 'T4_TOTAL', 'common'),
  ('t4 - total', 'T4_TOTAL', 'common'),
  -- ANTI_TPO
  ('anti tpo', 'ANTI_TPO', 'common'),
  ('anti-tpo', 'ANTI_TPO', 'common'),
  ('anti thyroid peroxidase antibody', 'ANTI_TPO', 'common'),
  ('tpo antibody', 'ANTI_TPO', 'common'),
  ('anti microsomal antibody', 'ANTI_TPO', 'common'),
  -- BILI_TOTAL
  ('total bilirubin', 'BILI_TOTAL', 'common'),
  ('bilirubin total', 'BILI_TOTAL', 'common'),
  ('bilirubin - total', 'BILI_TOTAL', 'common'),
  ('s. bilirubin (total)', 'BILI_TOTAL', 'indian_lab'),
  -- BILI_DIRECT
  ('direct bilirubin', 'BILI_DIRECT', 'common'),
  ('bilirubin direct', 'BILI_DIRECT', 'common'),
  ('bilirubin - direct', 'BILI_DIRECT', 'common'),
  ('conjugated bilirubin', 'BILI_DIRECT', 'common'),
  -- BILI_INDIRECT
  ('indirect bilirubin', 'BILI_INDIRECT', 'common'),
  ('bilirubin indirect', 'BILI_INDIRECT', 'common'),
  ('bilirubin - indirect', 'BILI_INDIRECT', 'common'),
  ('unconjugated bilirubin', 'BILI_INDIRECT', 'common'),
  -- ALT
  ('sgpt', 'ALT', 'indian_lab'),
  ('alt', 'ALT', 'common'),
  ('sgpt (alt)', 'ALT', 'indian_lab'),
  ('alt (sgpt)', 'ALT', 'indian_lab'),
  ('alanine transaminase', 'ALT', 'common'),
  ('alanine aminotransferase', 'ALT', 'common'),
  ('sgpt / alt', 'ALT', 'indian_lab'),
  -- AST
  ('sgot', 'AST', 'indian_lab'),
  ('ast', 'AST', 'common'),
  ('sgot (ast)', 'AST', 'indian_lab'),
  ('ast (sgot)', 'AST', 'indian_lab'),
  ('aspartate transaminase', 'AST', 'common'),
  ('aspartate aminotransferase', 'AST', 'common'),
  ('sgot / ast', 'AST', 'indian_lab'),
  -- ALP
  ('alkaline phosphatase', 'ALP', 'common'),
  ('alp', 'ALP', 'common'),
  ('alkaline phosphatase (alp)', 'ALP', 'common'),
  ('s. alkaline phosphatase', 'ALP', 'indian_lab'),
  -- GGT
  ('ggt', 'GGT', 'common'),
  ('gamma gt', 'GGT', 'common'),
  ('gamma glutamyl transferase', 'GGT', 'common'),
  ('gamma gt (ggt)', 'GGT', 'common'),
  ('ggtp', 'GGT', 'indian_lab'),
  -- PROTEIN_TOTAL
  ('total protein', 'PROTEIN_TOTAL', 'common'),
  ('protein total', 'PROTEIN_TOTAL', 'common'),
  ('serum total protein', 'PROTEIN_TOTAL', 'common'),
  ('s. protein (total)', 'PROTEIN_TOTAL', 'indian_lab'),
  -- ALBUMIN
  ('albumin', 'ALBUMIN', 'common'),
  ('serum albumin', 'ALBUMIN', 'common'),
  ('s. albumin', 'ALBUMIN', 'indian_lab'),
  -- GLOBULIN
  ('globulin', 'GLOBULIN', 'common'),
  ('serum globulin', 'GLOBULIN', 'common'),
  ('s. globulin', 'GLOBULIN', 'indian_lab'),
  -- AG_RATIO
  ('a/g ratio', 'AG_RATIO', 'common'),
  ('albumin globulin ratio', 'AG_RATIO', 'common'),
  ('albumin / globulin ratio', 'AG_RATIO', 'common'),
  -- UREA
  ('blood urea', 'UREA', 'common'),
  ('urea', 'UREA', 'common'),
  ('serum urea', 'UREA', 'common'),
  ('s. urea', 'UREA', 'indian_lab'),
  -- BUN
  ('bun', 'BUN', 'common'),
  ('blood urea nitrogen', 'BUN', 'common'),
  ('urea nitrogen', 'BUN', 'common'),
  -- CREATININE
  ('creatinine', 'CREATININE', 'common'),
  ('serum creatinine', 'CREATININE', 'common'),
  ('s. creatinine', 'CREATININE', 'indian_lab'),
  ('creatinine - serum', 'CREATININE', 'common'),
  -- EGFR
  ('egfr', 'EGFR', 'common'),
  ('estimated gfr', 'EGFR', 'common'),
  ('gfr estimated', 'EGFR', 'common'),
  ('e-gfr', 'EGFR', 'common'),
  -- URIC_ACID
  ('uric acid', 'URIC_ACID', 'common'),
  ('serum uric acid', 'URIC_ACID', 'common'),
  ('s. uric acid', 'URIC_ACID', 'indian_lab'),
  -- UACR
  ('urine albumin creatinine ratio', 'UACR', 'common'),
  ('acr', 'UACR', 'common'),
  ('microalbumin creatinine ratio', 'UACR', 'common'),
  -- GLUCOSE_FASTING
  ('fasting blood sugar', 'GLUCOSE_FASTING', 'indian_lab'),
  ('fbs', 'GLUCOSE_FASTING', 'indian_lab'),
  ('glucose fasting', 'GLUCOSE_FASTING', 'common'),
  ('fasting glucose', 'GLUCOSE_FASTING', 'common'),
  ('blood sugar fasting', 'GLUCOSE_FASTING', 'indian_lab'),
  ('glucose - fasting', 'GLUCOSE_FASTING', 'common'),
  ('fasting plasma glucose', 'GLUCOSE_FASTING', 'common'),
  ('sugar fasting', 'GLUCOSE_FASTING', 'indian_lab'),
  -- GLUCOSE_PP
  ('post prandial blood sugar', 'GLUCOSE_PP', 'indian_lab'),
  ('ppbs', 'GLUCOSE_PP', 'indian_lab'),
  ('pp blood sugar', 'GLUCOSE_PP', 'indian_lab'),
  ('glucose post prandial', 'GLUCOSE_PP', 'indian_lab'),
  ('post prandial glucose', 'GLUCOSE_PP', 'indian_lab'),
  ('blood sugar pp', 'GLUCOSE_PP', 'indian_lab'),
  ('glucose - pp (2 hrs)', 'GLUCOSE_PP', 'common'),
  ('2 hour postprandial glucose', 'GLUCOSE_PP', 'common'),
  -- GLUCOSE_RANDOM
  ('random blood sugar', 'GLUCOSE_RANDOM', 'indian_lab'),
  ('rbs', 'GLUCOSE_RANDOM', 'indian_lab'),
  ('glucose random', 'GLUCOSE_RANDOM', 'common'),
  ('blood sugar random', 'GLUCOSE_RANDOM', 'indian_lab'),
  -- HBA1C
  ('hba1c', 'HBA1C', 'common'),
  ('hba1c (glycosylated haemoglobin)', 'HBA1C', 'common'),
  ('glycosylated haemoglobin', 'HBA1C', 'common'),
  ('glycated haemoglobin', 'HBA1C', 'common'),
  ('glycosylated hemoglobin', 'HBA1C', 'common'),
  ('hb a1c', 'HBA1C', 'common'),
  ('a1c', 'HBA1C', 'common'),
  ('hba1c - glycated haemoglobin', 'HBA1C', 'common'),
  -- INSULIN_FASTING
  ('fasting insulin', 'INSULIN_FASTING', 'common'),
  ('insulin fasting', 'INSULIN_FASTING', 'common'),
  ('serum insulin (fasting)', 'INSULIN_FASTING', 'common'),
  -- VITD_25OH
  ('25 oh vitamin d', 'VITD_25OH', 'common'),
  ('vitamin d', 'VITD_25OH', 'common'),
  ('vitamin d (25-oh)', 'VITD_25OH', 'common'),
  ('vitamin d total', 'VITD_25OH', 'common'),
  ('25-hydroxy vitamin d', 'VITD_25OH', 'common'),
  ('25(oh)d', 'VITD_25OH', 'common'),
  ('vit d', 'VITD_25OH', 'indian_lab'),
  ('vit d (25-oh)', 'VITD_25OH', 'indian_lab'),
  ('vitamin d 25 hydroxy', 'VITD_25OH', 'common'),
  ('25-oh vitamin d total', 'VITD_25OH', 'common'),
  -- VITB12
  ('vitamin b12', 'VITB12', 'common'),
  ('b12', 'VITB12', 'common'),
  ('vit b12', 'VITB12', 'indian_lab'),
  ('cobalamin', 'VITB12', 'common'),
  ('vitamin b-12', 'VITB12', 'common'),
  ('serum vitamin b12', 'VITB12', 'common'),
  ('vitamin b12 (cobalamin)', 'VITB12', 'common'),
  -- FOLATE
  ('folate', 'FOLATE', 'common'),
  ('folic acid', 'FOLATE', 'common'),
  ('serum folate', 'FOLATE', 'common'),
  ('vitamin b9', 'FOLATE', 'common'),
  -- VITA
  ('vitamin a', 'VITA', 'common'),
  ('retinol', 'VITA', 'common'),
  ('serum retinol', 'VITA', 'common'),
  -- FERRITIN
  ('ferritin', 'FERRITIN', 'common'),
  ('serum ferritin', 'FERRITIN', 'common'),
  ('s. ferritin', 'FERRITIN', 'indian_lab'),
  ('ferritin - serum', 'FERRITIN', 'common'),
  -- IRON
  ('serum iron', 'IRON', 'common'),
  ('iron', 'IRON', 'common'),
  ('s. iron', 'IRON', 'indian_lab'),
  ('iron - serum', 'IRON', 'common'),
  -- TIBC
  ('tibc', 'TIBC', 'common'),
  ('total iron binding capacity', 'TIBC', 'common'),
  ('total iron binding capacity (tibc)', 'TIBC', 'common'),
  -- UIBC
  ('uibc', 'UIBC', 'common'),
  ('unsaturated iron binding capacity', 'UIBC', 'common'),
  -- TRANSFERRIN_SAT
  ('transferrin saturation', 'TRANSFERRIN_SAT', 'common'),
  ('% transferrin saturation', 'TRANSFERRIN_SAT', 'common'),
  ('transferrin saturation (%)', 'TRANSFERRIN_SAT', 'common'),
  ('iron saturation', 'TRANSFERRIN_SAT', 'common'),
  ('tsat', 'TRANSFERRIN_SAT', 'common'),
  -- CALCIUM
  ('calcium', 'CALCIUM', 'common'),
  ('serum calcium', 'CALCIUM', 'common'),
  ('s. calcium', 'CALCIUM', 'indian_lab'),
  ('total calcium', 'CALCIUM', 'common'),
  ('calcium - total', 'CALCIUM', 'common'),
  -- CALCIUM_IONIZED
  ('ionised calcium', 'CALCIUM_IONIZED', 'common'),
  ('ionized calcium', 'CALCIUM_IONIZED', 'common'),
  ('calcium ionised', 'CALCIUM_IONIZED', 'common'),
  -- PHOSPHORUS
  ('phosphorus', 'PHOSPHORUS', 'common'),
  ('serum phosphorus', 'PHOSPHORUS', 'common'),
  ('inorganic phosphorus', 'PHOSPHORUS', 'common'),
  ('phosphate', 'PHOSPHORUS', 'common'),
  -- MAGNESIUM
  ('magnesium', 'MAGNESIUM', 'common'),
  ('serum magnesium', 'MAGNESIUM', 'common'),
  ('s. magnesium', 'MAGNESIUM', 'indian_lab'),
  -- SODIUM
  ('sodium', 'SODIUM', 'common'),
  ('serum sodium', 'SODIUM', 'common'),
  ('s. sodium', 'SODIUM', 'indian_lab'),
  ('na+', 'SODIUM', 'common'),
  ('sodium (na)', 'SODIUM', 'common'),
  -- POTASSIUM
  ('potassium', 'POTASSIUM', 'common'),
  ('serum potassium', 'POTASSIUM', 'common'),
  ('s. potassium', 'POTASSIUM', 'indian_lab'),
  ('k+', 'POTASSIUM', 'common'),
  ('potassium (k)', 'POTASSIUM', 'common'),
  -- CHLORIDE
  ('chloride', 'CHLORIDE', 'common'),
  ('serum chloride', 'CHLORIDE', 'common'),
  ('s. chloride', 'CHLORIDE', 'indian_lab'),
  ('chloride (cl)', 'CHLORIDE', 'common'),
  -- BICARBONATE
  ('bicarbonate', 'BICARBONATE', 'common'),
  ('serum bicarbonate', 'BICARBONATE', 'common'),
  ('hco3', 'BICARBONATE', 'common'),
  ('co2 (bicarbonate)', 'BICARBONATE', 'common'),
  -- CRP_HS
  ('hs crp', 'CRP_HS', 'common'),
  ('hs-crp', 'CRP_HS', 'common'),
  ('high sensitivity crp', 'CRP_HS', 'common'),
  ('crp (high sensitivity)', 'CRP_HS', 'common'),
  ('c reactive protein (hs)', 'CRP_HS', 'common'),
  -- HOMOCYSTEINE
  ('homocysteine', 'HOMOCYSTEINE', 'common'),
  ('serum homocysteine', 'HOMOCYSTEINE', 'common'),
  ('total homocysteine', 'HOMOCYSTEINE', 'common'),
  -- PSA
  ('psa', 'PSA', 'common'),
  ('prostate specific antigen', 'PSA', 'common'),
  ('total psa', 'PSA', 'common'),
  ('psa total', 'PSA', 'common'),
  -- CPK
  ('cpk', 'CPK', 'common'),
  ('creatine phosphokinase', 'CPK', 'common'),
  ('ck total', 'CPK', 'common'),
  ('creatine kinase', 'CPK', 'common'),
  -- AMYLASE
  ('amylase', 'AMYLASE', 'common'),
  ('serum amylase', 'AMYLASE', 'common'),
  -- LIPASE
  ('lipase', 'LIPASE', 'common'),
  ('serum lipase', 'LIPASE', 'common'),
  -- LDH
  ('ldh', 'LDH', 'common'),
  ('lactate dehydrogenase', 'LDH', 'common'),
  ('lactic dehydrogenase', 'LDH', 'common'),
  -- CORTISOL_AM
  ('cortisol', 'CORTISOL_AM', 'common'),
  ('serum cortisol', 'CORTISOL_AM', 'common'),
  ('cortisol - morning', 'CORTISOL_AM', 'common'),
  ('cortisol (am)', 'CORTISOL_AM', 'common'),
  -- PTH
  ('pth', 'PTH', 'common'),
  ('parathyroid hormone', 'PTH', 'common'),
  ('intact pth', 'PTH', 'common'),
  ('pth intact', 'PTH', 'common'),
  -- TESTOSTERONE_TOTAL
  ('total testosterone', 'TESTOSTERONE_TOTAL', 'common'),
  ('testosterone', 'TESTOSTERONE_TOTAL', 'common'),
  ('testosterone total', 'TESTOSTERONE_TOTAL', 'common'),
  -- PROLACTIN
  ('prolactin', 'PROLACTIN', 'common'),
  ('serum prolactin', 'PROLACTIN', 'common'),
  ('prl', 'PROLACTIN', 'common')
on conflict (synonym) do nothing;

-- ---------------------------------------------------------------------------
-- Absolute neutrophil count and serum zinc. Added alongside the codes in
-- 200_biomarkers.sql; without these a report printing "ANC" would never reach
-- the neutropenia red-flag rule.
-- ---------------------------------------------------------------------------
insert into public.biomarker_synonyms (synonym, biomarker_code, source) values
  ('absolute neutrophil count', 'NEUTROPHILS_ABS', 'common'),
  ('anc', 'NEUTROPHILS_ABS', 'common'),
  ('neutrophil absolute count', 'NEUTROPHILS_ABS', 'indian_lab'),
  ('absolute neutrophils', 'NEUTROPHILS_ABS', 'common'),
  ('neutrophils absolute', 'NEUTROPHILS_ABS', 'indian_lab'),
  ('neutrophil count absolute', 'NEUTROPHILS_ABS', 'indian_lab'),
  ('serum zinc', 'ZINC', 'common'),
  ('zinc', 'ZINC', 'common'),
  ('zinc serum', 'ZINC', 'indian_lab'),
  ('zn', 'ZINC', 'common')
on conflict (synonym) do nothing;

-- ---------------------------------------------------------------------------
-- Names taken verbatim from a real 18-page AHC hybrid panel issued in Hyderabad
-- in September 2026. Half of the test names on that report did not match any
-- synonym seeded from general knowledge, which is why report-derived synonyms
-- matter more than plausible-sounding ones. Note the missing and irregular
-- spacing ("bilirubin -direct", "unsat.iron-binding capacity(uibc)") -- that is
-- how the lab prints it, and the normaliser has to cope with it.
-- ---------------------------------------------------------------------------
insert into public.biomarker_synonyms (synonym, biomarker_code, source) values
  ('alanine transaminase (sgpt)', 'ALT', 'indian_lab'),
  ('aspartate aminotransferase (sgot)', 'AST', 'indian_lab'),
  ('gamma glutamyl transferase (ggt)', 'GGT', 'indian_lab'),
  ('blood urea nitrogen (bun)', 'BUN', 'indian_lab'),
  ('est. glomerular filtration rate (egfr)', 'EGFR', 'indian_lab'),
  ('albumin - serum', 'ALBUMIN', 'indian_lab'),
  ('protein - total', 'PROTEIN_TOTAL', 'indian_lab'),
  ('bilirubin - total', 'BILI_TOTAL', 'indian_lab'),
  ('bilirubin -direct', 'BILI_DIRECT', 'indian_lab'),
  ('bilirubin (indirect)', 'BILI_INDIRECT', 'indian_lab'),
  ('creatinine - serum', 'CREATININE', 'indian_lab'),
  ('serum globulin', 'GLOBULIN', 'indian_lab'),
  ('serum alb/globulin ratio', 'AG_RATIO', 'indian_lab'),
  ('ldl cholesterol - direct', 'LDL', 'indian_lab'),
  ('hdl cholesterol - direct', 'HDL', 'indian_lab'),
  ('tc/ hdl cholesterol ratio', 'CHOL_HDL_RATIO', 'indian_lab'),
  ('hdl / ldl ratio', 'LDL_HDL_RATIO', 'indian_lab'),
  ('trig / hdl ratio', 'TRIG_HDL_RATIO', 'indian_lab'),
  ('fasting blood sugar(glucose)', 'GLUCOSE_FASTING', 'indian_lab'),
  ('average blood glucose (abg)', 'AVG_GLUCOSE', 'indian_lab'),
  ('tsh - ultrasensitive', 'TSH', 'indian_lab'),
  ('total triiodothyronine (t3)', 'T3_TOTAL', 'indian_lab'),
  ('total thyroxine (t4)', 'T4_TOTAL', 'indian_lab'),
  ('25-oh vitamin d (total)', 'VITD_25OH', 'indian_lab'),
  ('total iron binding capacity (tibc)', 'TIBC', 'indian_lab'),
  ('unsat.iron-binding capacity(uibc)', 'UIBC', 'indian_lab'),
  ('prostate specific antigen (psa)', 'PSA', 'indian_lab'),
  ('platelet distribution width(pdw)', 'PDW', 'indian_lab'),
  ('platelet distribution width', 'PDW', 'common'),
  ('pdw', 'PDW', 'common'),
  ('mean platelet volume', 'MPV', 'common'),
  ('mpv', 'MPV', 'common'),
  ('total rbc', 'RBC', 'indian_lab'),
  ('erythrocyte sedimentation rate (esr)', 'ESR', 'indian_lab')
on conflict (synonym) do nothing;



-- Check: this must print 353.
select count(*) as synonyms_loaded from public.biomarker_synonyms;

-- Check: no synonym points at a biomarker that does not exist (0 rows expected).
select s.synonym, s.biomarker_code
from public.biomarker_synonyms s
left join public.biomarkers b on b.code = s.biomarker_code
where b.code is null;
