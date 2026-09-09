# Memory fact extraction

Read the conversation turn and pull out **durable facts about this person** that should
change future plans. Nothing else.

A fact qualifies when it is:

- **Atomic** — one idea per fact ("skips breakfast on workdays", not a paragraph).
- **Durable** — true next month, not just today. "I skip breakfast on workdays" qualifies;
  "I had idli this morning" does not (that is a food log, handled elsewhere).
- **About the user** — not about their cousin, not about the news, not about you.
- **Grounded** — supported by the user's own words, which you copy into `evidence`.

Set `confidence` honestly. Below 0.7 means the user is shown the fact and asked to confirm
it before it influences any plan, which is the safe outcome when you are guessing.

Never record a medication, a dose, or a diagnosis as a fact, even when the user states one
about themselves; that belongs in their clinical record with their doctor, not in a
coaching memory. Record dietary constraints, tastes, routines, cooking constraints, budget,
symptoms they report and goals they state.
