---
name: morning-briefing
description: Short spoken briefing of today's calendar, reminders and battery
version: 1.0.0
platforms: [ios]
metadata:
  hermes:
    category: productivity
    tags: [calendar, reminders, daily]
---

# Morning briefing

1. Call calendar_events with startDay 0 and days 1.
2. Call reminders_list with includeCompleted false. Keep only items due today or overdue, plus up to 3 undated ones.
3. Call device_status only if the user asked about the phone or the battery.
4. Reply in at most 5 short sentences: first event and its time, how many meetings, any gap longer than 2 hours, the reminders that matter today.

Pitfalls
- Siri reads this aloud: no bullet lists, no emoji, times as "9:30", not "09:30".
- If USER.md holds a preference about the briefing (length, what to skip), follow it over these defaults.
