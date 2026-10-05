# Hermes for iPhone

A port of the [Hermes Agent](https://github.com/NousResearch/hermes-agent) harness (Nous Research, MIT) to iOS 27. It runs on Apple's on-device Foundation Model and is triggered by Siri. No server, no API key. By default nothing leaves the phone.

Hermes is a model plus a harness: memory, skills, session search, context compression, a learning loop, cron, and tools. This repo rebuilds the harness in Swift around `FoundationModels`, sized for the on-device model's **8,192-token** context.

> Is the original plan accurate? Mostly. The context is 8K now, not 4K, and apps don't get the Gemini-built "Siri AI" model. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md).

## Status

**v0.1, not yet compiled.** The code was written against the iOS 27 SDK as documented at WWDC26, in a Linux environment with no Xcode. Expect a few compile fixes on first build. Every SDK-specific call into Foundation Models is in [`Sources/HermesKit/Models/ModelProvider.swift`](Sources/HermesKit/Models/ModelProvider.swift), so that's the first place to look.

## How it maps to Hermes

| Hermes | Here |
|---|---|
| `~/.hermes/memories/MEMORY.md`, `USER.md` (§ entries, char budgets, frozen snapshot, `memory` tool) | `MemoryStore`: same format and rules. Budgets 1,200 / 700 chars (Hermes: 2,200 / 1,375) |
| `~/.hermes/skills/**/SKILL.md`, `skills_list` / `skill_view` / `skill_manage` | `SkillStore` + the same three tools. Bundled starter skills in `Resources/BundledSkills` |
| `state.db` + FTS5 + `session_search` | `SessionStore` (SQLite, FTS5) + `session_search` |
| Context compressor | Rolling per-session summary. Recent turns kept verbatim (`HistoryFitter`) |
| Background review (learning loop) | `LearningLoop.swift`: Hermes' review prompt, condensed. Runs when the app backgrounds or on charger |
| Toolsets | `Router`: picks only the toolsets a request needs, so tool schemas fit in 8K |
| `delegate_task` subagents | Same, sequential, one level deep |
| Cron | `CronStore` + `cronjob` tool. Runs from a Shortcuts automation / background refresh / app open, with results as notifications |
| `SOUL.md` | `SOUL.md` in the app container |
| `/skill-name`, `/new` | Same, plus `/think` (Private Cloud Compute) and `/local` |
| CLI / Telegram / Discord gateways | Siri (App Intents) + the app |

Device tools: `device_status`, `calendar_events`, `create_calendar_event`, `reminders_list`, `create_reminder`, `web_fetch`, `run_shortcut` (any of your Shortcuts: HomeKit, Messages, Music…), `cronjob`, `delegate_task`.

## One turn

```
Siri / app / scheduled job
   → slash commands (/think, /local, /<skill>)
   → Router: toolsets + model tier (on-device unless you opted into PCC)
   → instructions = SOUL.md + date + memory snapshot (frozen at session start) + skills index + summary
   → fit recent turns into what's left of 8K; summarize the overflow
   → LanguageModelSession(model, tools: only the routed ones).respond(...)   ← framework runs the tool loop
   → store messages + tool log; flag the session for the learning loop
```

If the model still overflows, the harness squeezes the history harder and retries. If you allowed it, it then retries on Private Cloud Compute.

## Build and run

Requirements: a Mac with Xcode 27, an iPhone that supports Apple Intelligence (the iPhone 18 Pro does) on iOS 27, with Apple Intelligence turned on.

```bash
brew install xcodegen
xcodegen generate
open Hermes.xcodeproj
```

1. In `project.yml`, set `bundleIdPrefix` and the `com.example.hermes.*` identifiers to your own, and set your team in Signing. Change the BG task IDs in `App/HermesRuntime.swift` to match.
2. Run on the device. Allow notifications. Calendar and Reminders permissions are requested the first time Hermes uses them.
3. Siri: "Ask Hermes" → "What should Hermes do?" → your request.
4. Scheduled jobs: ask "every weekday at 7:30 give me my morning briefing". Then for exact timing, in Shortcuts › Automation › + › Time of Day, pick 7:30, add **Run Hermes Scheduled Jobs**, and choose Run Immediately.

`swift test` (on macOS 27) runs the unit tests for memory, skills, session search, cron, routing and context fitting.

## Layout

```
Package.swift                 HermesKit (the harness), Swift package
Sources/HermesKit/
  Agent/      HermesAgent (the loop), PromptBuilder, ContextBudget, Router,
              Compression, LearningLoop, SlashCommands
  Memory/     MemoryStore
  Skills/     SkillStore
  Sessions/   SessionStore (SQLite + FTS5)
  Cron/       CronStore, CronRunner (+ notifications)
  Models/     ModelProvider: all Foundation Models SDK specifics
  Tools/      memory, skills, session_search, device, calendar/reminders,
              web_fetch, run_shortcut, cronjob, delegate_task
  Resources/  SOUL.md, BundledSkills/
App/                          SwiftUI app + App Intents (Siri), background tasks
project.yml                   XcodeGen spec for the iOS app
docs/FEASIBILITY.md           What's true, what isn't, what of Hermes can't run on iOS
```

## Known limits

- The on-device model is small. It's good at routing to tools, short answers, summaries and extraction. It's weak at long reasoning and code. Use `/think` with Private Cloud Compute for those, if you're OK with Apple's private cloud.
- iOS has no always-on background process. Scheduled jobs need the Shortcuts automation for exact timing.
- `run_shortcut` only works while the app is on screen, because it opens the Shortcuts app.
- No terminal, code execution or browser automation: the iOS sandbox doesn't allow them.

## Next steps

- First compile on Xcode 27 and fix SDK mismatches.
- Use iOS 27 `DynamicProfile` for routing instead of a fresh session per turn.
- Add a `LanguageModel` conformer that forwards hard requests to your Mac (MLX) or to Claude, as a third tier.
- Use the system `OCRTool` and Spotlight search tool, plus Contacts and Photos tools.
- Add an editor for SOUL.md, memory entries and skills in the app.
