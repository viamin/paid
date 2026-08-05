---
parent: PAID
prefix: CONFIG-PROFILES
---

# Low-Level Design: Configuration Profiles Chat

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the proposed chat-driven configuration-profile workflow for
> applying vetted operating modes across tenant, user, and project settings.

## Purpose

RDR-044 identifies a product gap rather than a missing primitive. Paid already
ships interactive chat and several settings-write tools, but it does not yet
ship the higher-level profile flow that turns requests like "make this project
fully automated" into a reviewed, batched configuration plan.

This segment records the intended design contract so future implementation work
can target EARS IDs instead of relying on RDR prose alone.

## Planned Behavior

The intended flow is:

- enumerate vetted configuration profiles
- recommend a profile from natural-language intent
- ask clarifying questions where profile choice needs operator input
- render a deterministic before/after plan for the affected tenant, user, and
  project settings
- apply the batched plan behind one confirmation instead of N per-field writes

Profiles are code-curated, version-controlled operating modes. The LLM chooses
from that registry; it does not invent arbitrary settings bundles.

## Existing Foundations

The implementation can build on already-shipped primitives:

- chat tool dispatch with confirmation modes
- existing write tools for user and tenant settings
- audit logging of settings mutations
- project/tenant/user settings models with established defaults

## Remaining Gap

The core profile flow is now shipped, including vetted profile discovery,
multi-scope planning, project/user/tenant application, and one-confirmation
batched writes. The main follow-up work still tracked separately is narrower:

- broaden profile coverage and reconcile it with the older legacy posture
  registry
- add dedicated profile audit/rollback semantics instead of relying on generic
  settings-changed activity metadata

## What this is not

- **Not a generic arbitrary settings editor.** The profile system constrains
  the LLM to vetted bundles plus bounded overrides.
- **Not runtime-configured policy data.** Profile definitions remain code.
- **Not a silent auto-apply path.** Human review of the generated plan remains
  part of the contract.
