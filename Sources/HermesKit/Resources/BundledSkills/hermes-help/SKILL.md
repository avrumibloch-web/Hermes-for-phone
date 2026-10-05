---
name: hermes-help
description: How Hermes works - models, slash commands, memory, scheduling, Siri
version: 1.0.0
platforms: [ios]
metadata:
  hermes:
    category: hermes
---

# Hermes on iPhone and Mac: how to use it

- Siri: say "Ask Hermes", then the request. Siri requests within 30 minutes of each other share one conversation.
- Models: Apple's on-device model answers by default (fast, offline, free). A "smart model" can be set in Settings: a local open model such as Qwen3 run with MLX (free, offline after download; best on a Mac), or Apple's Private Cloud Compute (free with a daily limit, needs internet). Hard requests go to the smart model automatically.
- Slash commands at the start of a message: /new starts a fresh conversation. /think uses the smart model for this message. /fast uses Apple's on-device model. /<skill-name> loads that skill first, e.g. /morning-briefing.
- Memory: Hermes keeps two small notebooks. USER.md holds facts about the user, MEMORY.md holds facts about their setup. Both are visible and editable in the app's Memory tab. New facts show up in the next conversation.
- Skills: saved procedures, like this one. Hermes can write new ones when it works out a repeatable workflow; they are listed in the Memory tab.
- Scheduled jobs: ask "every weekday at 7:30 give me my briefing". For on-time runs the user adds a Shortcuts automation: Shortcuts app › Automation › + › Time of Day › pick the job's time › action "Run Hermes Scheduled Jobs" › Run Immediately. One automation per time of day is enough for all jobs due then. Without it, jobs run when iOS gives Hermes background time or when the app opens.
- Shortcuts: Hermes can start any of the user's Shortcuts by name (home scenes, messages, music). On iPhone only while the app is open; on the Mac in the background.
- Privacy: Apple's on-device model and local MLX models run on the device. Only web_fetch and Private Cloud Compute (if chosen) use the network.
- Mac only: Hermes stays in the menu bar so scheduled jobs run on time; disk_usage shows what's using storage; Shortcuts run in the background with their output returned; the terminal tool runs shell commands if enabled in Settings.
