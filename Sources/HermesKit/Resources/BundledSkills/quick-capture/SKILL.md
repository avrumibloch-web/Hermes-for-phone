---
name: quick-capture
description: Turn a spoken brain-dump into separate reminders with due times
version: 1.0.0
platforms: [ios]
metadata:
  hermes:
    category: productivity
    tags: [reminders, capture]
---

# Quick capture

1. Split the user's message into separate actionable items. Ignore filler.
2. For each item call create_reminder once. Give it a due time only when the user said one ("tomorrow at 9", "Friday"); convert it to YYYY-MM-DD HH:mm using today's date from the instructions. "Tomorrow" without a time means 09:00.
3. Reply with one line: how many reminders were added and the first few titles.

Pitfalls
- Never merge two tasks into one reminder.
- Titles start with a verb ("Call the dentist"), at most 8 words.
