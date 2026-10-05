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

## "Let Siri AI be the agent, my app is just the tools"

Partly possible. The catch is **App Schemas**.

| Claim | Verdict | Notes |
|---|---|---|
| Siri AI combines its models with your app's actions and content through App Intents | **True** | App Intents is the only way in. SiriKit is deprecated. |
| Siri AI can chain actions across apps (model → tool → result → model) | **True, for schema actions** | There is a new system orchestrator. Apple's example chains three apps in one request. |
| Siri AI will decide to use *any* of your app's tools from natural language | **False** | Apple, in the WWDC26 Apple Intelligence lab: "You must adopt a schema to integrate with the new Siri AI." Schemas are Apple-designed shapes grouped into domains: messages, mail, photos, calendar, reminders, audio, timers, system search/open, and more. Siri reasons over actions and content that adopt one. |
| "Siri, check my Mac's storage and if there's less than 100 GB free, tell me what's using it" | **Not as one open-ended request** | There's no schema for "Mac storage", so Siri AI won't plan around that tool. Custom intents still reach Siri, but only as **App Shortcuts** with fixed phrases you supply ("Check my Mac with Hermes"). |
| Your app can orchestrate other apps' intents | **False** | No third-party-to-third-party invocation. Only the system orchestrator does that. |

So "Siri AI is the brain" works for things that fit a schema. Examples: reminders, calendar events, messages, notes-like documents, media. For everything else (your Mac, Pi, Jellyfin, servers), there are three routes. This repo supports all three:

1. **App Shortcut phrases** → a plain App Intent. Siri runs it and speaks the result. It's fixed-phrase, with no reasoning in between. (`GetPhoneStatusIntent`, `RunSkillIntent`, `RememberIntent`…)
2. **Shortcuts + "Use Model"**: Apple's model as the brain over your tools. Each toolbox intent returns a value. In a Shortcut, chain them and hand the output to the built-in **Use Model** action (on-device or Private Cloud Compute) to apply the logic ("if under 100 GB, list what's using it"). Then give the Shortcut a Siri name. This is the closest thing to "Siri is the agent" for custom tools.
3. **"Ask Hermes"**: an open-ended request goes to the Foundation Models agent in this repo, which can call the custom tools itself. Apple lets your app run that model with tools ("agentic app experiences"). It's the only route where a model freely decides which custom tool to use.

The longer-term move is to **adopt schemas where the tools fit**. Make reminders, calendar events and documents real App Entities with schemas (`IndexedEntity`, Spotlight). Then Siri AI can answer questions about them and act on them directly, with Hermes nowhere in the loop. The available schema names are listed in Xcode 27's autocomplete and the App Intents docs. They aren't in this repo yet because I couldn't verify the exact identifiers without the SDK.

Sources for this section: [WWDC26 session 240: Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/), [WWDC26 Apple Intelligence group lab](https://developer.apple.com/videos/play/wwdc2026/8011/) (community notes: [ivan-magda/wwdc26-notes](https://github.com/ivan-magda/wwdc26-notes)), [NowSecure on App Intents and Siri AI](https://www.nowsecure.com/blog/2026/08/05/what-appsec-teams-need-to-know-about-app-intents-siri-ai-and-the-new-ios-27-attack-surface/).

## Sources

- [WWDC26: What's new in the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2026/241/) (8,192-token on-device context, `LanguageModel` protocol, PCC model, tools, dynamic profiles)
- [Apple Developer: What's new in iOS](https://developer.apple.com/ios/whats-new/) (Core AI)
- [Tech Times: Foundation Models swaps AI providers without code changes](https://www.techtimes.com/articles/318039/20260609/wwdc-2026-developer-tools-foundation-models-now-swaps-ai-providers-without-code-changes.htm)
- [Mac Observer: Does Siri AI use Google Gemini?](https://www.macobserver.com/tips/round-ups/does-siri-ai-use-google-gemini/)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) (memory, skills, session search, background review, cron)
