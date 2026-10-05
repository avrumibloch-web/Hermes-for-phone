# Hermes for iPhone and Mac

A port of the [Hermes Agent](https://github.com/NousResearch/hermes-agent) harness (Nous Research, MIT) that runs on your own Apple devices. **No Nvidia GPU, no API subscription, no server.** The brain is Apple's Foundation Models framework, plus optional open models run locally.

Hermes is a model plus a harness: memory, skills, session search, context compression, a learning loop, cron, and tools. This repo rebuilds the harness in Swift around `FoundationModels`.

## Models: all free

Every model is used through the same Foundation Models API (`LanguageModelSession`, `Tool`, `@Generable`), so the harness doesn't care which one answers.

| Tier | What | Cost | Where it runs | Context | Good for |
|---|---|---|---|---|---|
| **Fast** (default) | Apple on-device model (`SystemLanguageModel`) | Free | iPhone / Mac, offline | 8K | Most requests: tool use, short answers, summaries |
| **Smart, local** | Open model via MLX, e.g. Qwen3 (`MLXLanguageModel`) | Free (one download) | iPhone / Mac GPU, offline | 16K+ (you choose) | Harder requests, longer context, everything on a big Mac |
| **Smart, Apple cloud** | Private Cloud Compute (`PrivateCloudComputeLanguageModel`) | Free (daily limit per iCloud account) | Apple's private servers | 32K + reasoning | The hardest requests, when online |

Pick the smart model in Settings. Hard-looking requests go to it automatically. Type `/think` to force it or `/fast` to stay on Apple's model. If the smart model fails or hits its limit, Hermes falls back to the on-device model, and the other way round.

Which local model fits:

| Device | Model | Size |
|---|---|---|
| iPhone 18 Pro, any Apple-silicon Mac | `mlx-community/Qwen3-4B-4bit` | ~2.3 GB |
| Mac with 16 GB | `mlx-community/Qwen3-8B-4bit` | ~4.7 GB |
| Mac with 32 GB+ | `mlx-community/Qwen3-30B-A3B-4bit` (fast: 3B active) | ~17 GB |
| Mac with 32 GB+ | `mlx-community/Qwen3.6-27B-4bit` | ~15 GB |

Any `mlx-community` model id works. Those are the ones with tool calling that the MLX adapter knows.

> Siri is optional: it's only a voice trigger ("Ask Hermes"). Siri's own model isn't used. More background in [docs/FEASIBILITY.md](docs/FEASIBILITY.md).

## Status

**v0.2, not yet compiled.** It was written against the iOS/macOS 27 SDK as documented at WWDC26, plus the source of Apple's `mlx-swift-lm` adapter, in a Linux environment with no Xcode. Expect a few compile fixes on first build.
- Foundation Models specifics are all in [`Sources/HermesKit/Models/ModelProvider.swift`](Sources/HermesKit/Models/ModelProvider.swift).
- MLX specifics are all in [`Sources/HermesLocalModels/MLXLocalModel.swift`](Sources/HermesLocalModels/MLXLocalModel.swift).

## How it maps to Hermes

| Hermes | Here |
|---|---|
| `MEMORY.md`, `USER.md` (§ entries, char budgets, frozen snapshot, `memory` tool) | `MemoryStore`: same format and rules. Budgets 1,200 / 700 chars (Hermes: 2,200 / 1,375) |
| `skills/**/SKILL.md`, `skills_list` / `skill_view` / `skill_manage` | `SkillStore` + the same tools. Skills named in a message load automatically, with the tools they use |
| `state.db` + FTS5 + `session_search` | `SessionStore` (SQLite, FTS5) |
| Context compressor | Rolling per-session summary. Recent turns kept verbatim |
| Background review (learning loop) | `LearningLoop.swift`. Runs when the app backgrounds or on charger (iPhone), or every 15 min (Mac) |
| Toolsets | `Router`: only the tools a request needs, so they fit in 8K |
| `delegate_task` | Same: a fresh-context helper, one level deep |
| Cron | `cronjob` tool. On the Mac it's a real clock (menu bar app). On iPhone: Shortcuts automation, background refresh, or app open |
| Terminal tool | Mac only, off by default, chat window only, with a blocklist |
| `SOUL.md` | `SOUL.md` in the app container |
| `/skill`, `/new` | Same, plus `/think` and `/fast` |

Tools:
- **Both devices:** `memory`, `skills_list`, `skill_view`, `skill_manage`, `session_search`, `device_status`, `calendar_events`, `create_calendar_event`, `reminders_list`, `create_reminder`, `web_fetch`, `run_shortcut`, `cronjob`, `delegate_task`.
- **Mac only:** `disk_usage` and `terminal`. On the Mac, `run_shortcut` also runs headless and returns the Shortcut's output.

The same tools are also plain App Intents (`App/Intents/ToolboxIntents.swift`), so Shortcuts and Spotlight can use them directly.

## Build and run

You need Xcode 27 on a Mac, and iOS 27 / macOS 27 with Apple Intelligence turned on.

```bash
brew install xcodegen
xcodegen generate
open Hermes.xcodeproj
```

1. In `project.yml`, set `bundleIdPrefix`, the bundle ids and your team. Keep the BG task ids in `App/HermesRuntime.swift` in sync.
2. Pick a scheme: **Hermes** (iPhone) or **HermesMac**. On first build Xcode asks you to trust the macros from `mlx-swift-lm`. Allow them.
3. Optional local model: Settings › Smart model › Local open model › choose one › **Download / load model**.
4. Optional Private Cloud Compute: apps must apply to use it (apps under 2M downloads are eligible) on the Apple Developer website. Until approved, Settings shows it as unavailable.
5. Mac: to let `disk_usage` see `~/Library`, give Hermes Full Disk Access in System Settings › Privacy & Security. The terminal tool is under Settings › Tools.

`swift test` (on macOS 27) runs the unit tests for memory, skills, session search, cron, routing and context fitting.

## Layout

```
Package.swift
Sources/HermesKit/          the harness (no MLX dependency)
  Agent/      HermesAgent (the loop + model selection), PromptBuilder, ContextBudget,
              Router, Compression, LearningLoop, SlashCommands
  Memory/ Skills/ Sessions/ Cron/
  Models/     ModelProvider: Foundation Models specifics, LocalModelProvider protocol
  Tools/      all tools; MacTools.swift = terminal, disk_usage
  Resources/  SOUL.md, BundledSkills/
Sources/HermesLocalModels/  MLXLocalModel: open models through Apple's MLX adapter
App/                        SwiftUI app shared by iPhone and Mac, App Intents, background work
project.yml                 XcodeGen: Hermes (iOS) and HermesMac targets
docs/FEASIBILITY.md         What's true, what isn't, what of Hermes can't run on Apple devices
```

## Known limits

- Apple's on-device model is small (~3B). The smart tiers exist for anything that needs real reasoning.
- Local models need RAM. A 4B model on iPhone works but is slower than Apple's model. A Mac is where local models shine.
- iPhone has no always-on background process, so scheduled jobs there need the Shortcuts automation for exact timing. The Mac doesn't.
- The Mac app runs without the App Sandbox, so it's for personal use, not the Mac App Store.

## Next steps

- First compile on Xcode 27, and fix SDK mismatches.
- Phone → Mac hand-off: let the iPhone send hard requests to the Mac's bigger local model over your home network.
- Use iOS 27 `DynamicProfile` instead of a fresh session per turn.
- Run evals (Apple's new Evaluations framework) to tune when to escalate.
