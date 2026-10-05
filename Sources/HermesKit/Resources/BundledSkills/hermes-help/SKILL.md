---
name: hermes-help
description: How Hermes on iPhone works - Siri, slash commands, memory, scheduling
version: 1.0.0
platforms: [ios]
metadata:
  hermes:
    category: hermes
---

# Hermes on iPhone: how to use it

- Siri: say "Ask Hermes", then the request. Siri requests within 30 minutes of each other share one conversation.
- Slash commands at the start of a message: /new starts a fresh conversation. /think sends the message to Apple's Private Cloud Compute model if the user enabled it in Settings. /local forces the on-device model. /<skill-name> loads that skill first, e.g. /morning-briefing.
- Memory: Hermes keeps two small notebooks. USER.md holds facts about the user, MEMORY.md holds facts about their setup. Both are visible and editable in the app's Memory tab. New facts show up in the next conversation.
- Skills: saved procedures, like this one. Hermes can write new ones when it works out a repeatable workflow; they are listed in the Memory tab.
- Scheduled jobs: ask "every weekday at 7:30 give me my briefing". For on-time runs the user adds a Shortcuts automation: Shortcuts app › Automation › + › Time of Day › pick the job's time › action "Run Hermes Scheduled Jobs" › Run Immediately. One automation per time of day is enough for all jobs due then. Without it, jobs run when iOS gives Hermes background time or when the app opens.
- Shortcuts: Hermes can start any of the user's Shortcuts by name (home scenes, messages, music) while the app is open on screen.
- Privacy: the model runs on the iPhone. Only web_fetch and, if enabled, /think and auto-escalation use the network.
