# Is the plan true? Claim-by-claim check (October 2026, iOS 27)

| Claim | Verdict | Notes |
|---|---|---|
| Your app can use the same on-device model that powers Apple Intelligence via the Foundation Models framework | **True** | `SystemLanguageModel` in the `FoundationModels` framework. Free, offline, no API key. |
| Apple supports agentic apps with tool calling | **True** | The `Tool` protocol + `@Generable` arguments. The framework runs the model → tool → model loop itself. |
| Runs offline | **True** for the on-device model | `PrivateCloudComputeLanguageModel` (new in iOS 27) is server-side: Apple's private cloud, not the phone. |
| iOS 27 lets other models conform to the `LanguageModel` protocol | **True** | New in iOS 27. `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform, and Apple ships open-source `CoreAILanguageModel` / `MLXLanguageModel` conformers. Anthropic and Google publish Swift packages for their models. |
| Core AI lets developers package and run their own models | **True** | New in iOS 27: a framework for bringing your own model files on-device, with control over CPU/GPU/Neural Engine. |
| Context size is 4,096 tokens | **Outdated** | That was iOS 26. In iOS 27 the on-device model reports `contextSize == 8192`. PCC is 32K. Still small: this harness is built around that limit. |
| The on-device model is weak at complex reasoning and code | **True** | Apple says so. It's a small model. It handles tool routing, summarizing, extraction and short answers well. |
| "Siri AI" is what your app gets | **Not quite** | The new Siri in iOS 27 runs Apple models built with Google Gemini, partly in Private Cloud Compute. Third-party apps do **not** get that model directly. They get the Foundation Models framework (the on-device model, and the PCC model). |
| Siri can trigger your agent | **True, with a caveat** | Through App Intents + App Shortcuts. You say "Ask Hermes", Siri asks "What should Hermes do?", you say the request. iOS doesn't let a free-form sentence go into the trigger phrase itself. |
| It won't overheat | **Mostly** | The on-device model is designed for the Neural Engine, and short requests are cheap. Long multi-tool turns still cost battery. This harness keeps heavy background work (the learning loop) on charger-only `BGProcessingTask`s. |
| "A small Hermes/OpenClaw-style agent running locally on your iPhone" | **True, with limits** | See below. |

## What of Hermes can run on an iPhone

| Hermes feature | On iPhone | How this repo does it |
|---|---|---|
| Agent loop with tools | ✅ | `LanguageModelSession` + `Tool`s |
| MEMORY.md / USER.md, frozen snapshot, add/replace/remove, char budgets | ✅ | `MemoryStore` (same file format and rules, smaller budgets) |
| Skills (`SKILL.md`, progressive disclosure, `skill_manage`) | ✅ | `SkillStore`, `skills_list`, `skill_view`, `skill_manage` |
| Session search (SQLite FTS5) | ✅ | `SessionStore` (same design as `state.db`) |
| Context compression | ✅ (needed much more often) | Rolling summary per session, `HistoryFitter` |
| Learning loop (background review → memory/skills) | ✅ (deferred) | Sessions are flagged, then reviewed when the app goes to the background or on charger |
| Subagents / delegation | ✅ (sequential, one level) | `delegate_task`: fresh context, short answer back |
| Cron | ⚠️ partial | No daemons on iOS. Jobs run from a Shortcuts "Time of Day" automation (exact), `BGAppRefreshTask` (iOS decides when), or app launch |
| SOUL.md personality | ✅ | Editable `SOUL.md` in the app container |
| `/skill` slash commands, `/new` | ✅ | Plus `/think` (PCC) and `/local` |
| Terminal backends, code execution, `execute_code` | ❌ | iOS apps can't spawn processes. The way around it is a Mac/server tool, not on-device |
| Browser automation, computer use | ❌ | Not possible in the iOS sandbox |
| 20+ messaging gateways (Telegram, Discord…) | ❌ on-device | These need an always-on process. The equivalent is Siri + the app + notifications |
| Big-model reasoning | ⚠️ | Opt-in Private Cloud Compute (`/think`), or a `LanguageModel` conformer for Claude/your Mac later |
| Controlling other apps, HomeKit, Messages | ⚠️ | No public API for most of it. `run_shortcut` starts any Shortcut by name (foreground only) |

## Sources

- [WWDC26: What's new in the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/) (8,192-token on-device context, `LanguageModel` protocol, PCC model, tools, dynamic profiles)
- [Apple Developer: What's new in iOS](https://developer.apple.com/ios/whats-new/) (Core AI)
- [Tech Times: Foundation Models swaps AI providers without code changes](https://www.techtimes.com/articles/318039/20260609/wwdc-2026-developer-tools-foundation-models-now-swaps-ai-providers-without-code-changes.htm)
- [Mac Observer: Does Siri AI use Google Gemini?](https://www.macobserver.com/tips/round-ups/does-siri-ai-use-google-gemini/)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) (memory, skills, session search, background review, cron)
