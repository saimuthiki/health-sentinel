# Data model

Postgres on Supabase. **Every user-owned table carries `user_id uuid references auth.users`
and has Row Level Security enabled** with the policy `auth.uid() = user_id`. The database
itself refuses to return another user's row, even if application code has a bug.

Reference tables (`biomarkers`, `reference_ranges`, `foods`, `rda_targets`) are shared,
read-only to clients, and writable only by the service role.

## Identity and profile
| Table | Key columns |
|---|---|
| `profiles` | `user_id` pk, display_name, locale, timezone, created_at |
| `health_profiles` | `user_id` pk, dob, sex, height_cm, weight_kg, activity_level, diet_type (`veg`/`non_veg`/`egg`/`vegan`/`jain`), cuisine_pref, city, pincode, wake_time, sleep_time, meal_times jsonb, conditions text[], updated_at |
| `allergies` | id, `user_id`, allergen, severity |
| `consents` | id, `user_id`, consent_type, version, accepted_at, ip_hash |

## Reports and results
| Table | Key columns |
|---|---|
| `reports` | id, `user_id`, storage_path, file_hash **(unique per user — dedupe)**, mime_type, report_type, lab_name, collected_on, status (`uploaded`/`extracting`/`extracted`/`failed`), keep_original_until, created_at |
| `report_extractions` | id, report_id, model, raw_json jsonb, tokens_in, tokens_out, created_at |
| `lab_results` | id, report_id, `user_id`, biomarker_code, value numeric, unit, printed_range, ref_low, ref_high, status (`critical_low`…`critical_high`), needs_review bool, confirmed_by_user bool, measured_on date |
| `biomarkers` *(reference)* | code pk, display_name, category, canonical_unit, higher_is_worse bool |
| `biomarker_synonyms` *(reference)* | synonym pk, biomarker_code, source |
| `reference_ranges` *(reference)* | id, biomarker_code, sex, age_min, age_max, pregnancy, low, high, borderline_low, borderline_high, critical_low, critical_high, source_citation |

`source_citation` is mandatory on every reference range — we must always be able to say
where a threshold came from.

## Symptoms, goals, memory
| Table | Key columns |
|---|---|
| `symptoms` | id, `user_id`, label, onset, severity, pattern, source_message_id, status, created_at |
| `symptom_followups` | id, symptom_id, question, answer, asked_at, answered_at |
| `goals` | id, `user_id`, goal_type (`weight`/`hair`/`skin`/`energy`/`sleep`/`fitness`/`deficiency`), title, target, priority, status, created_at, closed_at |
| `user_memory` | id, `user_id`, fact, category, confidence numeric, confirmed bool, source_message_id, created_at, expires_at |

## Nutrition
| Table | Key columns |
|---|---|
| `foods` *(reference)* | id pk, name, name_local, food_group, per_100g jsonb (kcal, protein_g, fat_g, carb_g, fibre_g, iron_mg, calcium_mg, vitamin_d_ug, b12_ug, folate_ug, zinc_mg …), diet_flags text[], allergens text[], region, source (`IFCT2017`/`USDA`), source_id |
| `recipes` *(reference)* | id, name, cuisine, meal_slots text[], prep_minutes, diet_flags, steps |
| `recipe_items` | recipe_id, food_id, grams |
| `rda_targets` *(reference)* | id, nutrient, sex, age_min, age_max, activity_level, amount, unit, source (`ICMR-NIN 2020`) |
| `food_preferences` | id, `user_id`, food_id, stance (`like`/`dislike`/`neutral`/`never`), score numeric, updated_at |
| `food_logs` | id, `user_id`, logged_at, meal_slot, food_id nullable, free_text, image_path, source (`planned`/`chat`/`photo`/`manual`) |
| `food_feedback` | id, `user_id`, food_log_id, rating smallint (1-5), note |

## Plans, grocery, alerts
| Table | Key columns |
|---|---|
| `meal_plans` | id, `user_id`, plan_date, generated_at, model, rationale, status |
| `meal_plan_items` | id, meal_plan_id, meal_slot, recipe_id nullable, food_id nullable, grams, computed_nutrients jsonb, why_text, order_index |
| `grocery_lists` | id, `user_id`, week_start, status |
| `grocery_items` | id, grocery_list_id, food_id, quantity, unit, aisle, state (`need`/`have`/`bought`) |
| `pantry_items` | id, `user_id`, food_id, quantity, unit, updated_at |
| `alerts` | id, `user_id`, alert_type (`hydration`/`meal`/`grocery`/`activity`/`sleep`/`nutrition`/`report_followup`/`weekly_summary`/`escalation`), title, body, schedule_rule, enabled, quiet_hours jsonb |
| `alert_deliveries` | id, alert_id, `user_id`, fired_at, opened_at, actioned_at, action |

## Conversation, audit, deletion
| Table | Key columns |
|---|---|
| `chat_threads` | id, `user_id`, title, created_at |
| `chat_messages` | id, thread_id, `user_id`, role (`user`/`assistant`/`system`), content, attachments jsonb, created_at |
| `health_events` | id, `user_id`, event_type, payload jsonb, occurred_at — the append-only audit trail |
| `ai_runs` | id, `user_id`, task, model, prompt_hash, tokens_in, tokens_out, latency_ms, safety_verdict, regenerated bool, created_at |
| `weekly_summaries` | id, `user_id`, week_start, metrics jsonb, narrative, model, created_at |
| `deletion_requests` | id, `user_id`, requested_at, completed_at, objects_deleted int, rows_deleted int |

## Notes on your original sketch

Your sketch was correct in structure — this is the same design with four additions worth
naming:

1. **`biomarker_synonyms` and `reference_ranges` as reference tables.** Without these, "is
   this value abnormal?" would be a question for the model. With them, it is a lookup.
2. **`file_hash` unique per user.** Re-uploading the same report costs no model call.
3. **`ai_runs`.** You cannot control cost or debug a bad answer without a record of every
   model call. This is the difference between an app you can operate and one you can only
   hope about.
4. **`needs_review` / `confirmed_by_user` on `lab_results`.** The one place we must never
   guess is a health number.

## Retention

- Report **files**: deleted after `keep_original_until` (default 90 days) unless the user
  opts to keep them. Structured `lab_results` are kept — they are the trend history.
- `chat_messages`: kept until deletion is requested.
- `ai_runs`: prompt **hashes** only, never prompt contents. 180 days.
- **Delete all my health data**: removes every row above and every storage object, records a
  receipt in `deletion_requests`, and is covered by an automated test that fails if any table
  is missed.
