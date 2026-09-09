"""Drug and dose vocabularies for the deterministic validator.

Two working rules kept this list honest:

1. **Nothing that is also a food or a nutrient goes in.** "iron", "calcium", "vitamin D",
   "folate", "zinc", "protein", "omega-3", "turmeric" are *not* here. Naming a nutrient is
   coaching; naming ``Zincovit`` is recommending a product. The line is the product, not
   the molecule. :data:`NEVER_FLAG` records the words we deliberately refuse to flag and a
   test asserts none of them matches.
2. **Pharmaceutical preparations of nutrients do go in** -- ``cholecalciferol``,
   ``calcitriol``, ``methylcobalamin``, ``ferrous sulphate`` -- because those names only
   appear on a label, never in a kitchen.

Coverage is generic INN names plus the Indian brands a user is most likely to be holding.
It will never be complete; see the validator's module docstring for what that means.
"""

from __future__ import annotations

#: Generic (INN) drug names.
GENERIC_DRUGS: frozenset[str] = frozenset(
    {
        # diabetes
        "metformin", "glimepiride", "gliclazide", "glipizide", "glibenclamide",
        "sitagliptin", "vildagliptin", "linagliptin", "teneligliptin", "saxagliptin",
        "empagliflozin", "dapagliflozin", "canagliflozin", "pioglitazone", "acarbose",
        "insulin", "semaglutide", "liraglutide", "dulaglutide", "tirzepatide", "repaglinide",
        # thyroid
        "levothyroxine", "thyroxine", "liothyronine", "carbimazole", "methimazole",
        "propylthiouracil",
        # lipids
        "atorvastatin", "rosuvastatin", "simvastatin", "pravastatin", "pitavastatin",
        "statin", "fenofibrate", "gemfibrozil", "ezetimibe", "bempedoic acid",
        # blood pressure / cardiac
        "telmisartan", "losartan", "olmesartan", "valsartan", "irbesartan", "candesartan",
        "amlodipine", "nifedipine", "cilnidipine", "ramipril", "enalapril", "lisinopril",
        "perindopril", "metoprolol", "atenolol", "bisoprolol", "carvedilol", "propranolol",
        "nebivolol", "clonidine", "prazosin", "ivabradine", "digoxin", "nitroglycerin",
        "isosorbide", "sacubitril",
        # diuretics
        "hydrochlorothiazide", "chlorthalidone", "furosemide", "torsemide", "spironolactone",
        "indapamide", "eplerenone", "acetazolamide",
        # blood thinners
        "aspirin", "clopidogrel", "ticagrelor", "prasugrel", "warfarin", "acenocoumarol",
        "apixaban", "rivaroxaban", "dabigatran", "edoxaban", "heparin", "enoxaparin",
        # pain / fever / inflammation
        "paracetamol", "acetaminophen", "ibuprofen", "diclofenac", "aceclofenac",
        "naproxen", "etoricoxib", "indomethacin", "ketorolac", "mefenamic acid",
        "nimesulide", "piroxicam", "tramadol", "codeine", "morphine", "gabapentin",
        "pregabalin", "duloxetine", "amitriptyline",
        # steroids and immune
        "prednisolone", "prednisone", "methylprednisolone", "dexamethasone",
        "hydrocortisone", "betamethasone", "deflazacort", "corticosteroid",
        "methotrexate", "hydroxychloroquine", "sulfasalazine", "azathioprine",
        "mycophenolate", "tacrolimus", "cyclosporine", "leflunomide",
        # gastro
        "omeprazole", "pantoprazole", "esomeprazole", "rabeprazole", "lansoprazole",
        "ranitidine", "famotidine", "domperidone", "ondansetron", "metoclopramide",
        "sucralfate", "mebeverine", "dicyclomine", "rifaximin", "lactulose",
        "bisacodyl", "loperamide", "ursodeoxycholic acid",
        # antibiotics / antimicrobials
        "azithromycin", "amoxicillin", "clavulanate", "ampicillin", "cloxacillin",
        "cefixime", "cefuroxime", "ceftriaxone", "cephalexin", "cefpodoxime",
        "ciprofloxacin", "levofloxacin", "ofloxacin", "norfloxacin", "moxifloxacin",
        "doxycycline", "minocycline", "clarithromycin", "clindamycin", "metronidazole",
        "tinidazole", "ornidazole", "nitrofurantoin", "fluconazole", "itraconazole",
        "ketoconazole", "terbinafine", "griseofulvin", "albendazole", "mebendazole",
        "ivermectin", "acyclovir", "valacyclovir", "oseltamivir", "rifampicin",
        "isoniazid", "pyrazinamide", "ethambutol", "trimethoprim", "sulfamethoxazole",
        "cotrimoxazole", "vancomycin", "linezolid", "meropenem",
        # allergy / respiratory
        "cetirizine", "levocetirizine", "fexofenadine", "loratadine", "desloratadine",
        "chlorpheniramine", "hydroxyzine", "montelukast", "salbutamol", "albuterol",
        "levosalbutamol", "budesonide", "formoterol", "fluticasone", "ipratropium",
        "theophylline", "doxofylline", "ambroxol", "dextromethorphan", "pseudoephedrine",
        # psychiatry / neurology
        "sertraline", "escitalopram", "fluoxetine", "paroxetine", "venlafaxine",
        "desvenlafaxine", "mirtazapine", "bupropion", "alprazolam", "clonazepam",
        "lorazepam", "diazepam", "etizolam", "zolpidem", "quetiapine", "olanzapine",
        "risperidone", "aripiprazole", "haloperidol", "lithium carbonate", "lamotrigine",
        "levetiracetam", "valproate", "sodium valproate", "divalproex", "carbamazepine",
        "phenytoin", "topiramate", "sumatriptan", "rizatriptan", "flunarizine",
        "donepezil", "modafinil",
        # hormones / urology / gynaecology
        "levonorgestrel", "ethinylestradiol", "medroxyprogesterone", "progesterone",
        "estradiol", "clomiphene", "letrozole", "tamoxifen", "testosterone",
        "finasteride", "dutasteride", "minoxidil", "tamsulosin", "sildenafil",
        "tadalafil", "cabergoline", "bromocriptine",
        # bone / kidney / other prescription molecules
        "alendronate", "risedronate", "zoledronic acid", "denosumab", "teriparatide",
        "allopurinol", "febuxostat", "colchicine", "sevelamer", "cinacalcet",
        "erythropoietin", "darbepoetin",
        # pharmaceutical preparations of nutrients -- label words, never kitchen words
        "cholecalciferol", "ergocalciferol", "calcitriol", "alfacalcidol",
        "methylcobalamin", "cyanocobalamin", "hydroxocobalamin",
        "ferrous sulphate", "ferrous sulfate", "ferrous fumarate", "ferrous ascorbate",
        "iron sucrose", "carbonyl iron", "folinic acid", "potassium chloride",
        "calcium carbonate", "calcium citrate", "magnesium oxide",
    }
)

#: Brand names commonly seen on Indian prescriptions and strips.
BRAND_DRUGS: frozenset[str] = frozenset(
    {
        "thyronorm", "eltroxin", "thyrox", "thyrup", "lethyrox",
        "glycomet", "glucophage", "gluconorm", "amaryl", "januvia", "istamet", "jardiance",
        "galvus", "zita", "dapa", "trajenta", "obimet",
        "storvas", "atorva", "lipvas", "rosuvas", "rozavel", "crestor", "lipitor", "ecosprin",
        "telma", "telmikind", "amlong", "amlokind", "stamlo", "losar", "olmesar", "nebicard",
        "metolar", "concor", "cardivas", "envas", "ramistar",
        "lasix", "dytor", "aldactone", "nefrosave",
        "pan-d", "pan-40", "pantop", "pantocid", "omez", "razo", "rantac", "zinetac", "aciloc",
        "cyclopam", "meftal", "drotin", "digene", "gelusil", "eno", "duphalac", "cremaffin",
        "crocin", "dolo", "calpol", "combiflam", "brufen", "voveran", "zerodol", "nise",
        "flexon", "saridon", "disprin", "ultracet", "tramazac",
        "azee", "azithral", "zifi", "monocef", "taxim", "augmentin", "clavam", "moxikind",
        "cifran", "ciplox", "levoflox", "norflox", "flagyl", "metrogyl", "zenflox",
        "sporlac", "fluka", "sebifin",
        "allegra", "avil", "cetzine", "alerid", "montek", "montair", "asthalin", "duolin",
        "foracort", "seroflo", "budecort", "sinarest", "wikoryl", "cheston",
        "zoloft", "nexito", "cipralex", "prozac", "restyl", "alprax", "clonotril", "lonazep",
        "zapiz", "etilaam", "zolfresh", "oleanz",
        "shelcal", "calcirol", "uprise-d3", "d-rise", "arachitol", "bio-d3",
        "zincovit", "becosules", "neurobion", "polybion", "supradyn", "revital",
        "livogen", "orofer", "dexorange", "fefol", "autrin", "feronia", "hemsi",
        "folvite", "celin", "limcee",
        "evion", "renerve", "nurokind", "methycobal",
        "cetapin", "moxovas", "urimax", "veltam", "dutas", "finast", "mintop",
        "unwanted-72", "i-pill", "meprate", "duphaston", "krimson",
        "zyloric", "febutaz", "fosamax",
        "wysolone", "omnacortil", "medrol", "decdan", "hcqs", "folitrax", "imuran",
        "susten", "regestrone", "primolut",
    }
)

#: Words that must never be flagged as medication, whatever else changes. Tested.
NEVER_FLAG: frozenset[str] = frozenset(
    {
        "iron", "calcium", "vitamin", "vitamin d", "vitamin b12", "b12", "folate",
        "folic acid", "zinc", "magnesium", "potassium", "sodium", "protein", "fibre",
        "fiber", "omega-3", "turmeric", "ginger", "garlic", "amla", "ragi", "millet",
        "dal", "ghee", "curd", "paneer", "jaggery", "moringa", "methi", "spinach",
        "banana", "almond", "walnut", "flaxseed", "chia", "sesame", "coconut",
        "buttermilk", "sambar", "idli", "dosa", "roti", "chapati", "khichdi", "poha",
        "upma", "rajma", "chana", "peanut", "papaya", "guava", "supplement", "capsicum",
        "water", "milk", "egg", "chicken", "fish", "salt", "sugar", "honey", "oats",
    }
)


#: Units that are only ever pharmaceutical. A number next to one of these is a dose.
PHARMA_UNITS: tuple[str, ...] = (
    "mg", "milligram", "milligrams", "mcg", "microgram", "micrograms", "µg", "ug",
    "iu", "i.u.", "tablet", "tablets", "tab", "tabs", "capsule", "capsules",
    "cap", "caps", "sachet", "sachets", "pill", "pills", "ampoule", "ampoules",
    "puff", "puffs", "injection", "injections", "vial", "vials",
)

#: Dose-shaped but occasionally culinary. Suppressed when the sentence is about food.
AMBIGUOUS_UNITS: tuple[str, ...] = ("drop", "drops", "unit", "units", "dose", "doses")

#: Ordinary kitchen measures. Only a dose when a medicine word is in the same sentence.
FOOD_UNITS: tuple[str, ...] = (
    "g", "gm", "gms", "gram", "grams", "kg", "ml", "mls", "millilitre", "millilitres",
    "litre", "litres", "liter", "liters", "l", "tsp", "tbsp", "teaspoon", "teaspoons",
    "tablespoon", "tablespoons", "cup", "cups", "bowl", "bowls", "glass", "glasses",
    "slice", "slices", "piece", "pieces", "katori", "katoris",
)

#: Words that turn a quantity into a prescription: something is being *taken*.
MEDICINE_FORM_WORDS: frozenset[str] = frozenset(
    {
        "supplement", "supplements", "supplementation", "syrup", "tonic", "injection",
        "injections", "dose", "doses", "dosage", "medicine", "medicines", "medication",
        "medications", "drug", "drugs", "tablet", "tablets", "capsule", "capsules",
        "sachet", "sachets", "pill", "pills", "prescription", "prescribed",
        "sublingual", "intramuscular", "ampoule", "vial", "otc",
    }
)

#: Food nouns used to suppress an ambiguous-unit match ("2 drops of lemon juice").
FOOD_CONTEXT_WORDS: frozenset[str] = frozenset(
    {
        "juice", "lemon", "lime", "honey", "oil", "ghee", "milk", "water", "curd",
        "yogurt", "yoghurt", "tea", "coffee", "dal", "rice", "ragi", "oats", "salt",
        "sugar", "vinegar", "buttermilk", "coconut", "almond", "almonds", "walnut",
        "walnuts", "jaggery", "spinach", "moringa", "methi", "ginger", "garlic",
        "chutney", "sambar", "idli", "dosa", "roti", "chapati", "paneer", "chicken",
        "egg", "eggs", "fish", "banana", "apple", "papaya", "guava", "dates", "raisins",
        "peanut", "peanuts", "chana", "rajma", "poha", "upma", "khichdi", "soup",
        "salad", "millet", "wheat", "atta", "sprouts", "vegetable", "vegetables",
        "fruit", "fruits", "snack", "meal", "breakfast", "lunch", "dinner", "seeds",
        "nuts", "paratha", "curry", "sabzi", "raita", "lassi", "smoothie", "broth",
    }
)
