---
parent: PAID
prefix: ONBOARD-CHAT
---

# Low-Level Design: Onboarding Chat-Led Setup

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment records the planned chat-led onboarding flow tracked by the umbrella
> issue #4280. No implementation is claimed by this document; see
> `onboarding-chat-setup-specs.md` for per-claim status.

## Purpose

A brand-new Paid account cannot bootstrap itself into a working setup today.
The existing onboarding (`OnboardingController`, steps `account_profile →
github_token → first_project → configure_defaults`) covers identity, GitHub,
and posture, but never asks for a chat-capable API key or runner, never asks
what tools the user actually uses (Linear, agent-run runners), and offers no
way to ask "what is this setting for?" mid-flow. Users complete onboarding
with a chat session that immediately fails with `LlmClientConfigurationError`
("Chat requires a configured API-key runner…") and no guided path from there
to a minimal working setup.

This segment records the intended design so the tracked phase issues can
target EARS IDs instead of relying on issue prose alone.

## Planned Behavior

1. **API key first.** The first step onboarding asks for is a provider API
   key usable for chat, enumerated from `RunnerSupport::API_SERVICE_TYPES`
   (OpenRouter — free models exist — Anthropic, OpenAI, Google AI, DeepSeek,
   Mistral, …) rather than a hard-coded, divergent list.
2. **Start a chat with that key.** The key becomes a `ProviderApiKey`, a
   chat-enabled API-key `Runner`, and a `ChatSession`; the user lands *in*
   that chat rather than back on a form.
3. **Chat-guided setup.** The chat walks the user through the remaining
   minimal setup, adapting to what they report using: agent-run runners
   (container-executable keys from `RunnerSupport.addable_runner_keys`), a
   GitHub project (existing repo or `Projects::CreateBlank`), a GitHub
   connection (App install or PAT), Linear (tracker configuration) if used,
   and an operating profile (e.g. Human-led Feature Factory) via the existing
   configuration-profile plan/apply path.
4. **Q&A throughout.** At any point the user can ask what a setting is for or
   what Paid features exist; the assistant answers from a curated product
   docs corpus, never from model memory.
5. **Done = minimal setup.** The user has: a working chat, a project, a
   GitHub credential, an agent-run runner, optionally Linear, and a chosen
   profile. `OnboardingStep` state reflects what the chat actually
   configured, independent of whether the user went through chat or forms.

## Existing Foundations

The implementation builds on already-shipped primitives rather than new
infrastructure:

- `Tools::Registry.chat_definitions_for` already exposes provider API keys,
  runner-adjacent settings, GitHub issue tools, configuration profiles
  (`list/plan/apply_configuration_profile`), and read tools — see
  `docs/intent/chat-tool-confirmation/` and
  `docs/intent/configuration-profiles-chat/`.
- `ProjectsController#start_setup_chat` and `Projects::BuildSetupPrompt` are
  the precedent for chat-as-setup-interview and for injecting an adaptive
  persona into `ChatSessions::BuildSystemPrompt`.
- `Onboarding::StartOnboarding`, `Onboarding::CompleteStep`, and
  `Onboarding::DefaultPosture`/`Configuration::Profiles` are the precedent for
  transactional onboarding services and posture application.
- `Tools::CreateProviderApiKey` is the precedent for the write-tool
  confirmation contract (`write_operation?` + `confirmed`, stripped from the
  model-visible schema per RDR-028) that every new write tool in this segment
  follows.

## Phase Breakdown

Tracked under the umbrella (#4280):

- **Phase 0 — chat bootstrap** (#4281): the `chat_api_key` onboarding step,
  `Onboarding::ConfigureChatRunner`, key validation, and the chat handoff that
  gets a fresh account from "no key" to "chatting."
- **Phases 1–3 — onboarding chat tools and persona** (#4282): read tools
  (`get_onboarding_status`, `list_runners`, `get_account_capabilities`), write
  tools (`create_runner`, `create_tracker_configuration`, `create_project`,
  `complete_onboarding_step`), the `get_product_docs` corpus, and the
  onboarding persona section in `ChatSessions::BuildSystemPrompt`.
- **Phase 4 — v1 hardening** (folded into #4282): key validation edge cases,
  docs corpus review, and the security checklist (no secrets in tool results,
  scoped `provider_api_key_id` ownership checks, no internal-only content in
  the docs corpus).

## What This Is Not

- **Not a replacement for the step forms.** Users who prefer plain forms keep
  that path; the chat-led flow is additive and both share `OnboardingStep`
  state. No feature removes `OnboardingController`'s form steps.
- **Not a billing/plan setup flow.** Billing remains out of scope for this
  segment.
- **Not an in-chat OAuth handshake.** GitHub App installs and other
  OAuth-style connections link out to the existing controller flows; the chat
  never attempts to perform the handshake itself.
- **Not a free-form settings editor.** Write tools are narrowly scoped
  (create runner, create tracker configuration, create project, mark a step
  complete); there is deliberately no `skip_onboarding_step` tool, so the
  model cannot fast-forward the wizard on the human's behalf.

## Remaining Gap

Nothing in this segment is implemented yet; every claim in
`onboarding-chat-setup-specs.md` is an active gap (`[ ]`) until the tracked
phase issues (#4281, #4282) ship and update this document's status.
