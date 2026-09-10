"""Every name our own catalogue uses for something we measure.

Why a file of names exists at all
---------------------------------
A handful of words are simultaneously a **drug** and an **analyte we measure**:
``thyroxine`` (T4, on every Indian thyroid panel), ``insulin``, ``testosterone``,
``cholecalciferol`` (vitamin D3), ``cyanocobalamin`` (B12). The medication rail in
:mod:`app.safety.validator` has to tell

    "Your Free Thyroxine is 1.2 ng/dL, which is in the usual range."   -- a lab fact

from

    "Take thyroxine 50 mcg daily."                                     -- a prescription

and :mod:`app.safety.analytes` decides which terms need that distinction by looking them
up in this vocabulary. It is derived rather than hand-written on purpose: a list of four
strings typed out by hand rots the day somebody seeds an eighty-ninth biomarker, and the
next collision is another 500 on somebody's report.

Where the names come from
-------------------------
Two sources, unioned by :func:`analyte_names`:

1. ``SEEDED_DISPLAY_NAMES`` and ``SEEDED_SYNONYMS`` below, which mirror
   ``db/seed/200_biomarkers.sql`` (``display_name``) and
   ``db/seed/201_biomarker_synonyms.sql`` (``synonym``) row for row.
2. :mod:`app.rules.normalise`'s own catalogue -- ``BIOMARKERS`` display names and
   ``SYNONYMS`` keys -- read **live**, so a name added on the Python side needs no
   second edit here.

Why the seed is mirrored and not parsed
---------------------------------------
Parsing ``../db/seed/*.sql`` at import time would make this vocabulary depend on files
that are not part of the deployed artefact: the Render service's root directory is
``backend/`` and the Cloud Run target in ``docs/07-open-decisions.md`` is an image built
from it. A missing seed file at runtime would silently shrink the vocabulary, which
means silently *widening* the medication rail -- exactly the 500 this file exists to
prevent, and only in production. So the names are checked in, the validator stays pure
with no IO, and ``tests/safety/test_dual_use_analytes.py`` parses the two seed files and
fails if either set below has drifted from them. ``.github/workflows/backend.yml`` runs
on ``db/seed/**`` for that reason.

Adding a biomarker or a synonym to the seed therefore means adding it here too, and the
test tells you exactly which line to add.
"""

from __future__ import annotations

from app.rules.normalise import BIOMARKERS, SYNONYMS

#: ``display_name`` from ``db/seed/200_biomarkers.sql``, verbatim.
SEEDED_DISPLAY_NAMES: frozenset[str] = frozenset(
    {
        "Absolute Neutrophil Count", "Albumin", "Albumin / Globulin Ratio", "Alkaline Phosphatase",
        "Anti-Thyroid Peroxidase Antibody", "Apolipoprotein B",
        "Average Blood Glucose (from HbA1c)", "Basophils", "Blood Urea", "Blood Urea Nitrogen",
        "Creatine Phosphokinase", "Direct Bilirubin", "Eosinophils",
        "Erythrocyte Sedimentation Rate", "Estimated GFR", "Fasting Blood Glucose",
        "Fasting Insulin", "Ferritin", "Folate (Folic Acid)", "Free T3", "Free T4", "Gamma GT",
        "Globulin", "Glycated Haemoglobin (HbA1c)", "HDL Cholesterol", "Haemoglobin",
        "High Sensitivity C-Reactive Protein", "Homocysteine", "Indirect Bilirubin",
        "Ionised Calcium", "LDL / HDL Ratio", "LDL Cholesterol", "Lactate Dehydrogenase",
        "Lipoprotein (a)", "Lymphocytes", "Mean Corpuscular Haemoglobin",
        "Mean Corpuscular Haemoglobin Concentration", "Mean Corpuscular Volume",
        "Mean Platelet Volume", "Monocytes", "Neutrophils", "Non-HDL Cholesterol",
        "Packed Cell Volume (Haematocrit)", "Parathyroid Hormone", "Platelet Count",
        "Platelet Distribution Width", "Post Prandial Blood Glucose (2 hr)", "Prolactin",
        "Prostate Specific Antigen (Total)", "Random Blood Glucose", "Red Blood Cell Count",
        "Red Cell Distribution Width", "Reticulocyte Count", "SGOT (AST)", "SGPT (ALT)",
        "Serum Amylase", "Serum Bicarbonate", "Serum Calcium (Total)", "Serum Chloride",
        "Serum Cortisol (Morning)", "Serum Creatinine", "Serum Iron", "Serum Lipase",
        "Serum Magnesium", "Serum Phosphorus", "Serum Potassium", "Serum Sodium", "Serum Zinc",
        "Thyroid Stimulating Hormone", "Total Bilirubin", "Total Cholesterol",
        "Total Cholesterol / HDL Ratio", "Total Iron Binding Capacity",
        "Total Leucocyte Count (WBC)", "Total Protein", "Total T3", "Total T4",
        "Total Testosterone", "Transferrin Saturation", "Triglyceride / HDL Ratio", "Triglycerides",
        "Unsaturated Iron Binding Capacity", "Uric Acid", "Urine Albumin / Creatinine Ratio",
        "VLDL Cholesterol", "Vitamin A (Retinol)", "Vitamin B12 (Cobalamin)", "Vitamin D (25-OH)",
    }
)

#: ``synonym`` from ``db/seed/201_biomarker_synonyms.sql``, verbatim (all three inserts).
SEEDED_SYNONYMS: frozenset[str] = frozenset(
    {
        "% transferrin saturation", "2 hour postprandial glucose", "25 oh vitamin d", "25(oh)d",
        "25-hydroxy vitamin d", "25-oh vitamin d (total)", "25-oh vitamin d total", "a/g ratio",
        "a1c", "absolute neutrophil count", "absolute neutrophils", "acr",
        "alanine aminotransferase", "alanine transaminase", "alanine transaminase (sgpt)",
        "albumin", "albumin - serum", "albumin / globulin ratio", "albumin globulin ratio",
        "alkaline phosphatase", "alkaline phosphatase (alp)", "alp", "alt", "alt (sgpt)", "amylase",
        "anc", "anti microsomal antibody", "anti thyroid peroxidase antibody", "anti tpo",
        "anti-tpo", "apo b", "apo-b", "apolipoprotein b", "aspartate aminotransferase",
        "aspartate aminotransferase (sgot)", "aspartate transaminase", "ast", "ast (sgot)",
        "average blood glucose (abg)", "b12", "basophil", "basophils", "basophils %", "bicarbonate",
        "bilirubin (indirect)", "bilirubin - direct", "bilirubin - indirect", "bilirubin - total",
        "bilirubin -direct", "bilirubin direct", "bilirubin indirect", "bilirubin total",
        "blood haemoglobin", "blood sugar fasting", "blood sugar pp", "blood sugar random",
        "blood urea", "blood urea nitrogen", "blood urea nitrogen (bun)", "bun",
        "c reactive protein (hs)", "calcium", "calcium - total", "calcium ionised", "chloride",
        "chloride (cl)", "chol/hdl ratio", "cholesterol", "cholesterol - total",
        "cholesterol / hdl ratio", "cholesterol hdl", "cholesterol ldl", "cholesterol total",
        "ck total", "co2 (bicarbonate)", "cobalamin", "conjugated bilirubin", "cortisol",
        "cortisol (am)", "cortisol - morning", "cpk", "creatine kinase", "creatine phosphokinase",
        "creatinine", "creatinine - serum", "crp (high sensitivity)", "direct bilirubin", "e-gfr",
        "egfr", "eosinophil", "eosinophils", "eosinophils %", "erythrocyte count",
        "erythrocyte sedimentation rate", "erythrocyte sedimentation rate (esr)", "esr",
        "esr (westergren)", "est. glomerular filtration rate (egfr)", "estimated gfr",
        "fasting blood sugar", "fasting blood sugar(glucose)", "fasting glucose", "fasting insulin",
        "fasting plasma glucose", "fbs", "ferritin", "ferritin - serum", "folate", "folic acid",
        "free t3", "free t4", "free thyroxine", "free tri-iodothyronine", "free triiodothyronine",
        "ft3", "ft4", "gamma glutamyl transferase", "gamma glutamyl transferase (ggt)", "gamma gt",
        "gamma gt (ggt)", "gfr estimated", "ggt", "ggtp", "globulin", "glucose - fasting",
        "glucose - pp (2 hrs)", "glucose fasting", "glucose post prandial", "glucose random",
        "glycated haemoglobin", "glycosylated haemoglobin", "glycosylated hemoglobin",
        "haematocrit", "haemoglobin", "haemoglobin (hb)", "haemoglobin - hb", "hb", "hb a1c",
        "hba1c", "hba1c (glycosylated haemoglobin)", "hba1c - glycated haemoglobin", "hco3", "hct",
        "hdl", "hdl - cholesterol", "hdl / ldl ratio", "hdl cholesterol",
        "hdl cholesterol - direct", "hematocrit", "hemoglobin", "hemoglobin (hb)",
        "hemoglobin, blood", "hgb", "high density lipoprotein", "high sensitivity crp",
        "homocysteine", "hs crp", "hs-crp", "indirect bilirubin", "inorganic phosphorus",
        "insulin fasting", "intact pth", "ionised calcium", "ionized calcium", "iron",
        "iron - serum", "iron saturation", "k+", "lactate dehydrogenase", "lactic dehydrogenase",
        "ldh", "ldl", "ldl - cholesterol", "ldl / hdl ratio", "ldl cholesterol",
        "ldl cholesterol - calculated", "ldl cholesterol - direct", "ldl/hdl ratio",
        "leucocyte count", "lipase", "lipoprotein (a)", "lipoprotein a", "low density lipoprotein",
        "lp(a)", "lymphocyte", "lymphocytes", "lymphocytes %", "magnesium", "mch", "mchc", "mcv",
        "mean cell volume", "mean corpuscular haemoglobin",
        "mean corpuscular haemoglobin concentration", "mean corpuscular hemoglobin",
        "mean corpuscular hemoglobin concentration", "mean corpuscular volume",
        "mean platelet volume", "microalbumin creatinine ratio", "monocyte", "monocytes",
        "monocytes %", "mpv", "na+", "neutrophil", "neutrophil absolute count",
        "neutrophil count absolute", "neutrophils", "neutrophils %", "neutrophils absolute",
        "non hdl cholesterol", "non-hdl cholesterol", "packed cell volume",
        "packed cell volume (pcv)", "parathyroid hormone", "pcv", "pdw", "phosphate", "phosphorus",
        "platelet count", "platelet count (plt)", "platelet distribution width",
        "platelet distribution width(pdw)", "platelets", "plt", "polymorphs",
        "post prandial blood sugar", "post prandial glucose", "potassium", "potassium (k)",
        "pp blood sugar", "ppbs", "prl", "prolactin", "prostate specific antigen",
        "prostate specific antigen (psa)", "protein - total", "protein total", "psa", "psa total",
        "pth", "pth intact", "random blood sugar", "rbc", "rbc count", "rbs", "rdw", "rdw cv",
        "rdw-cv", "red blood cell count", "red cell distribution width", "retic count",
        "reticulocyte count", "reticulocytes", "retinol", "s. albumin", "s. alkaline phosphatase",
        "s. bilirubin (total)", "s. calcium", "s. chloride", "s. cholesterol", "s. creatinine",
        "s. ferritin", "s. globulin", "s. iron", "s. magnesium", "s. potassium",
        "s. protein (total)", "s. sodium", "s. triglycerides", "s. tsh", "s. urea", "s. uric acid",
        "sedimentation rate", "segmented neutrophils", "serum alb/globulin ratio", "serum albumin",
        "serum amylase", "serum bicarbonate", "serum calcium", "serum chloride",
        "serum cholesterol", "serum cortisol", "serum creatinine", "serum ferritin", "serum folate",
        "serum globulin", "serum homocysteine", "serum insulin (fasting)", "serum iron",
        "serum lipase", "serum magnesium", "serum phosphorus", "serum potassium", "serum prolactin",
        "serum retinol", "serum sodium", "serum total protein", "serum triglycerides", "serum urea",
        "serum uric acid", "serum vitamin b12", "serum zinc", "sgot", "sgot (ast)", "sgot / ast",
        "sgpt", "sgpt (alt)", "sgpt / alt", "sodium", "sodium (na)", "sugar fasting", "t3",
        "t3 - total", "t4", "t4 - total", "tc/ hdl cholesterol ratio", "tc/hdl ratio",
        "testosterone", "testosterone total", "tg", "thyroid stimulating hormone",
        "thyroid stimulating hormone (tsh)", "thyroxine", "thyroxine (t4)", "tibc", "tlc",
        "total bilirubin", "total calcium", "total cholesterol", "total cholesterol / hdl ratio",
        "total homocysteine", "total iron binding capacity", "total iron binding capacity (tibc)",
        "total leucocyte count", "total leucocyte count (tlc)", "total leukocyte count",
        "total platelet count", "total protein", "total psa", "total rbc", "total rbc count",
        "total t3", "total t4", "total testosterone", "total thyroxine (t4)",
        "total triiodothyronine (t3)", "total wbc count", "tpo antibody", "transferrin saturation",
        "transferrin saturation (%)", "tri-iodothyronine (t3)", "trig / hdl ratio", "triglyceride",
        "triglycerides", "triiodothyronine", "tsat", "tsh", "tsh - ultrasensitive",
        "tsh ultra sensitive", "uibc", "unconjugated bilirubin",
        "unsat.iron-binding capacity(uibc)", "unsaturated iron binding capacity", "urea",
        "urea nitrogen", "uric acid", "urine albumin creatinine ratio",
        "very low density lipoprotein", "vit b12", "vit d", "vit d (25-oh)", "vitamin a",
        "vitamin b-12", "vitamin b12", "vitamin b12 (cobalamin)", "vitamin b9", "vitamin d",
        "vitamin d (25-oh)", "vitamin d 25 hydroxy", "vitamin d total", "vldl", "vldl cholesterol",
        "wbc", "wbc count", "white blood cell count", "zinc", "zinc serum", "zn",
    }
)


def analyte_names() -> frozenset[str]:
    """Every name this codebase uses for something a lab measures.

    The seeded catalogue plus the Python one. Nothing is lower-cased or otherwise
    normalised here: callers match case-insensitively, and keeping the names verbatim is
    what lets the seed-parity test compare them with the SQL character for character.
    """
    return frozenset(
        SEEDED_DISPLAY_NAMES
        | SEEDED_SYNONYMS
        | {spec.display_name for spec in BIOMARKERS.values()}
        | set(SYNONYMS)
    )
