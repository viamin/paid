# RDR-030: GitHub App Bot Account for Repository Actions

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-09
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: TBD
- **Related RDRs**: [RDR-012](RDR-012-github-integration.md) (extends auth model), [RDR-022](RDR-022-auto-merge-pr-strategy.md) (consumes bot identity for PR authorship)
- **Related Tests**: `spec/services/github/`, `spec/models/github_installation_*`, `spec/requests/github_app/installations_spec.rb`

## Problem Statement

Today every repository action Paid takes — opening PRs, pushing branches, commenting, requesting reviews, merging — runs through a user-supplied **Personal Access Token (PAT)** stored on `GithubToken`. This works but is causing concrete pain:

1. **PR authorship collapses onto the human user.** PRs are authored by whoever owns the PAT, so the agent is indistinguishable from the human in `git log` and on the PR page. Workflows that assume `author != reviewer` break: CODEOWNERS self-review rules, branch protection "require review from someone other than the author," and human approval gates are all silently bypassed when the PAT owner is also the only reviewer.
2. **PAT ergonomics are bad.** Users must mint, scope, and rotate PATs; tokens expire silently; fine-grained PATs require per-repo grants and don't expose token-level permissions through the standard read APIs (we already have a probe-based workaround in `GithubToken#sync_repositories!`).
3. **Rate limits are tied to a single user.** All Paid traffic for a project consumes one human's 5,000/hr quota.
4. **No way to scope Paid's access independently of the user.** Revoking Paid means revoking a PAT that may also be used elsewhere; we cannot install/uninstall Paid on a per-repo basis the way customers expect.
5. **We already operate one GitHub App** (`paid-code-reviewer[bot]`, App ID `3340381`) for posting agent reviews. Customers see two distinct integrations (PAT + review bot) when they should see one.

The desired end state: a dedicated **`paid-agents` GitHub App** that customers install on the orgs/repos they want Paid to operate on, mirroring the operational pattern already used by `paid-code-reviewer[bot]`. `paid-agents[bot]` acts as the bot identity for all repo writes, and the PAT path remains as a fallback for cases the App can't cover (e.g., GitHub Enterprise Server without the App, BYO-app self-hosters who want their own identity).

## Context

### Background

- RDR-012 chose PAT-based polling for Phase 1 and explicitly noted GitHub App as the Phase 3 (SaaS) plan. We are now in Phase 3.
- The `paid-code-reviewer[bot]` App and its installation-token service (`Github::ReviewBotInstallationToken`) already prove the operational pattern — JWT app auth → installation token per repo → API calls. This RDR generalizes that pattern from "post reviews" to "do everything Paid does on a repo."
- Auto-merge (RDR-022) already implicitly assumes some workflows where author and reviewer are distinct; today it is held together by ad-hoc bot-login allowlists (`scan_paid_prs_activity.rb` keeps `BOT_LOGIN` lists for review/comment matching). A real bot author identity collapses several of those ad-hoc checks.
- Paid is multi-tenant. Whatever auth mechanism we pick must (a) work for hosted SaaS customers without manual ops, and (b) work for self-hosters on `paid` private cloud / on-prem who can't use Anthropic's canonical app.

### Technical Environment

- Rails 8 with `Octokit` for REST and a thin Faraday-based GraphQL client.
- Existing tenant scoping via `TenantContext`; `GithubToken` is account-scoped.
- Container agents authenticate to GitHub via the **secrets proxy** (RDR-006); they never see raw credentials. Whatever credential the proxy mints, agents continue to receive a short-lived token they treat as opaque.
- An existing GitHub App (`paid-code-reviewer`) already proves the JWT-signing → installation-token path inside the codebase.

### Constraints

- Must not break existing PAT-based projects on rollout. PAT remains a supported path.
- Must work on **GitHub Enterprise Server** and self-hosted Paid deployments where the canonical App may not be reachable / installable.
- Container agents must continue to receive only short-lived, narrowly-scoped credentials.
- Bot identity for PR authoring must be stable enough for branch protection, CODEOWNERS, and review-required rules to treat it as "not the human."

## Research Findings

### GitHub App vs PAT — Mechanics

| Aspect | PAT (today) | GitHub App (proposed) |
|---|---|---|
| Auth flow | User pastes token | One-click install on org/repo, OAuth-like |
| Token lifetime | User-set (often years) | Installation token: 1 hour, refreshable |
| Rate limit | 5,000 / hr per user | 5,000 / hr per **installation**, scales with repo count up to 12,500/hr |
| Permissions | User's permissions, with PAT-level scopes | Fine-grained, declared at app level, granted at install |
| Revocation | User revokes PAT (also affects other tools) | Customer uninstalls app from a single repo or org |
| PR authorship | Pasting user | `paid-agents[bot]` (or the configured app slug) |
| Webhooks | Not used | Available; first-class support for events |
| Multi-repo | One PAT covers all repos user can see | Granular: install only on repos customer wants |

### PR Authorship Implications

When a PR is opened with an installation token, GitHub records the author as `<app-slug>[bot]`. This is the unlock that motivated this RDR:

- **CODEOWNERS / required reviews**: branch protection rules that require approval from "someone other than the author" now actually fire for a human reviewer, because the bot — not the human — is the author.
- **Auto-merge gates**: rules like "require N human approvals" can finally distinguish agent PRs from human PRs cleanly.
- **Audit / observability**: `git log --author` and PR filters cleanly separate Paid-generated commits from human commits.
- **`scan_paid_prs_activity.rb`** currently maintains heuristic bot-login allowlists; with a stable `paid-agents[bot]` author we can simplify those checks and stop relying on commit message conventions.

### Installation Token Plumbing (already exists)

`Github::ReviewBotInstallationToken` is the working reference implementation. It:

1. Signs a JWT with the App's RSA private key (9-minute expiry, per GitHub's spec).
2. `GET /repos/:owner/:repo/installation` to discover the installation ID.
3. `POST /app/installations/:id/access_tokens` to mint a 1-hour installation token.
4. Returns the token; caller uses it for API calls.

We will generalize this into a `Github::AppInstallation` service with caching (installation tokens are expensive — 2 round-trips — and shouldn't be minted per request), per-installation rate-limit tracking, and per-repo permission scoping.

### Hybrid Deployment Model (chosen)

Three plausible deployment shapes:

- **Single canonical app** — one "Paid" app that everyone installs. Best UX, simplest ops, but unusable for self-hosters who can't reach the canonical app or whose repos are on GitHub Enterprise Server.
- **Per-tenant apps via manifest flow** — each Paid deployment registers its own app via [GitHub's app-manifest flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest). Works everywhere but adds setup friction and means "Paid" appears under different bot names for different deployments.
- **Hybrid (chosen)** — SaaS customers install a single canonical `paid-agents[bot]`. Self-hosters and Enterprise users register their own app via manifest flow on first-run admin setup, and the rest of the system treats whichever app is configured as "the Paid app" for that deployment.

The hybrid model lines up with how `paid-code-reviewer` already works: the App ID and private key are read from `ENV` first, then Rails credentials, with a `configured?` predicate. Self-hosters override; SaaS uses the default. We will mirror that pattern.

Until full app-backed repository auth is enabled everywhere, agent-run git commit metadata should resolve from the same deployment-level `paid-agents` identity source. That lets PAT-backed projects keep working while commits already align with the configured bot identity; deployments that have not configured `paid_agent_*` metadata yet may fall back to the legacy `Paid Agent <agent@paid-agents.com>` identity temporarily.

### PAT Coexistence

PAT is **not deprecated**. Per project, the credential source is one of:

- **App installation** (preferred) — `project.github_installation_id` is set; token minted per-request.
- **PAT** — `project.github_token_id` is set; existing path.

A project chooses one at creation; Paid prefers the App when both are configured. PAT remains the documented fallback for: GitHub Enterprise Server without app reachability, repos where the customer's GitHub admin can't install third-party apps, migration period for existing customers, and emergency break-glass when the App is broken.

## Proposed Solution

### Approach

1. Register a canonical **`paid-agents` GitHub App** for SaaS. Mirror the credential-config pattern from `paid-code-reviewer` (`PAID_AGENT_APP_ID`, `PAID_AGENT_APP_PRIVATE_KEY` env, then Rails credentials).
2. Add an **app-manifest flow** in admin settings that lets a self-hoster register their own app and have the resulting App ID + private key written into local credentials.
3. Generalize `Github::ReviewBotInstallationToken` into `Github::AppInstallation` — a per-`(app_id, repo_full_name)` token-mint service with TTL caching.
4. Add models: `GithubInstallation` (per-account record of which org/user installed Paid, with installation ID and granted repos) and a nullable `Project#github_installation_id` alongside the existing `Project#github_token_id`.
5. Add a project-level `github_credential` resolver that returns either an installation token or a PAT, opaque to callers. `GithubClient.new(...)` accepts whichever.
6. Switch all repo-write call sites to mint tokens via the resolver. Reads (polling, etc.) follow the same pattern.
7. Update `scan_paid_prs_activity.rb` bot-login matching: when the project uses an App, `BOT_LOGIN` is `<app-slug>[bot]` (no longer just the review bot). Drop ad-hoc heuristics where the new author identity makes them redundant.
8. Add a "Connect Paid to GitHub" UI flow that drives users through the App install, captures the post-install callback, persists the `GithubInstallation`, and offers a per-project picker of which repo to use.

### Technical Design

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                       PAID GITHUB APP ARCHITECTURE                            │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         APP REGISTRY (per Paid deployment)              │ │
│  │                                                                          │ │
│  │  Github::AppRegistry.current                                             │ │
│  │   ├─ app_id         (ENV → credentials)                                  │ │
│  │   ├─ private_key    (ENV → credentials)                                  │ │
│  │   ├─ slug           ("paid-agents" canonical, or self-hoster's choice)   │ │
│  │   └─ configured?    (false → PAT-only mode)                              │ │
│  │                                                                          │ │
│  │  Self-hosters bootstrap via manifest flow at /admin/github_app/setup,    │ │
│  │  which writes credentials and seeds the registry without a deploy.       │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    INSTALLATION & PROJECT BINDING                        │ │
│  │                                                                          │ │
│  │  GithubInstallation (per account)                                        │ │
│  │   ├─ account_id                                                          │ │
│  │   ├─ github_installation_id  (int from GitHub)                           │ │
│  │   ├─ account_login           ("acme-corp")                               │ │
│  │   ├─ target_type             ("Organization" | "User")                   │ │
│  │   ├─ repository_selection    ("all" | "selected")                        │ │
│  │   ├─ accessible_repositories (jsonb cache)                               │ │
│  │   └─ suspended_at, revoked_at                                            │ │
│  │                                                                          │ │
│  │  Project                                                                 │ │
│  │   ├─ github_installation_id  (nullable FK → GithubInstallation)          │ │
│  │   ├─ github_token_id         (existing, nullable FK → GithubToken)       │ │
│  │   └─ exactly one of the two must be set                                  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                       CREDENTIAL RESOLUTION                              │ │
│  │                                                                          │ │
│  │  project.github_credential                                               │ │
│  │   ├─ if installation present → Github::AppInstallation.token_for(repo)  │ │
│  │   │     (cached ~50 min, refreshes before 60-min GitHub expiry)         │ │
│  │   └─ else                    → project.github_token.token                │ │
│  │                                                                          │ │
│  │  Callers receive an opaque token + identity metadata; they don't care    │ │
│  │  which path produced it.                                                 │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                   AGENT-SIDE TOKEN DELIVERY (RDR-006)                    │ │
│  │                                                                          │ │
│  │  Containers ask the secrets proxy for a GitHub credential.               │ │
│  │  Proxy resolves via project.github_credential → returns short-lived      │ │
│  │  installation token (1 hour) when App is in use; PAT otherwise.          │ │
│  │  Agents use it for `git push`, PR creation, commenting — nothing else    │ │
│  │  in the agent code changes.                                              │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Hybrid deployment** — SaaS gets one-click install with a canonical bot identity; self-hosters retain control via manifest flow. Same code path for both at runtime.
2. **PAT kept as fallback** — avoids forced-migration churn for existing customers, covers GHES + locked-down orgs, gives us a break-glass.
3. **Reuse `paid-code-reviewer` patterns** — the JWT-sign + installation-token plumbing is already in production for review posts; we are generalizing, not inventing.
4. **Per-project credential resolver** — keeps activities and services agnostic to whether they're talking via App or PAT. Migration becomes a per-project flag flip, not a code change.
5. **Stable bot author identity** — the App's `paid-agents[bot]` PR authorship is the architectural payoff: it's what lets human-in-the-loop approval workflows finally function.

### Implementation Sketch

```ruby
# app/services/github/app_registry.rb
module Github
  class AppRegistry
    def self.configured?
      app_id.present? && private_key.present?
    end

    def self.app_id
      ENV["PAID_AGENT_APP_ID"].presence || credentials_dig(:paid_agent_app_id)
    end

    def self.slug
      ENV["PAID_AGENT_APP_SLUG"].presence || credentials_dig(:paid_agent_app_slug) || "paid-agents"
    end

    def self.private_key
      ENV["PAID_AGENT_APP_PRIVATE_KEY"].presence || credentials_dig(:paid_agent_app_private_key)
    end

    def self.bot_login
      "#{slug}[bot]"
    end

    def self.credentials_dig(key)
      Rails.application.credentials.dig(key).presence
    end
  end
end
```

```ruby
# app/services/github/app_installation.rb
module Github
  class AppInstallation
    TOKEN_TTL = 50.minutes  # GitHub gives 60; refresh early.

    def self.token_for(installation_id:, repo_full_name:)
      Rails.cache.fetch(cache_key(installation_id, repo_full_name), expires_in: TOKEN_TTL) do
        new(installation_id: installation_id, repo_full_name: repo_full_name).mint
      end
    end

    def mint
      jwt = AppJwt.sign(app_id: AppRegistry.app_id, private_key: AppRegistry.private_key)
      response = Faraday.post("#{API_BASE}/app/installations/#{installation_id}/access_tokens",
                              "{}",
                              "Authorization" => "Bearer #{jwt}",
                              "Accept" => "application/vnd.github+json",
                              "Content-Type" => "application/json")
      JSON.parse(response.body).fetch("token")
    end
  end
end
```

```ruby
# app/models/project.rb (additions)
class Project < ApplicationRecord
  belongs_to :github_installation, optional: true
  belongs_to :github_token, optional: true, counter_cache: true

  validate :exactly_one_github_credential

  def github_credential
    if github_installation_id.present?
      Github::AppInstallation.token_for(
        installation_id: github_installation.github_installation_id,
        repo_full_name: github_full_name
      )
    else
      github_token.token
    end
  end

  def github_author_login
    github_installation_id.present? ? Github::AppRegistry.bot_login : github_token&.created_by&.github_login
  end

  private

  def exactly_one_github_credential
    return if github_installation_id.present? ^ github_token_id.present?
    errors.add(:base, "must have either a GitHub App installation or a PAT, not both")
  end
end
```

### Migration Path

1. **Phase A — Land App support without flipping defaults.**
   Add `GithubInstallation`, `Project#github_installation_id`, `AppRegistry`, `AppInstallation`. Keep PAT as the default for new projects. Existing projects untouched. Add admin-only "Connect Paid to GitHub via App" UI for early adopters.
2. **Phase B — Make App the recommended path.**
   New projects default to the App flow when `AppRegistry.configured?`. PAT remains an explicit alternative on the project create form. Send in-product nudges to existing PAT projects to migrate.
3. **Phase C — Steady state.**
   Both paths supported indefinitely. PAT documented as a fallback for GHES, locked-down orgs, and break-glass.

## Alternatives Considered

### Alternative 1: Single Canonical App, No Manifest Flow

**Description**: Ship one `paid-agents` GitHub App and require everyone to install it.
**Pros**: Simplest UX, single bot identity globally, easiest support.
**Cons**: Self-hosters and GHES users can't install Anthropic's canonical app on their network. Cuts out the on-prem segment entirely.
**Reason for rejection**: Paid explicitly supports self-hosted deployments. A choice that breaks that segment is non-starter.

### Alternative 2: Per-Tenant Apps Only (Manifest Flow Mandatory)

**Description**: Every Paid deployment registers its own app on first run.
**Pros**: Uniform code path, works on all topologies.
**Cons**: Adds setup friction for SaaS customers (the majority); fragments bot identity ("which `something[bot]` do I trust?"); makes debugging cross-customer issues harder for support.
**Reason for rejection**: Worse SaaS UX for the larger segment. Hybrid gives manifest-flow benefits to those who need them without taxing everyone.

### Alternative 3: Hard-Cutover from PAT to App

**Description**: Ship App support, sunset PAT in 90 days, remove the code path.
**Pros**: One code path long-term; cleaner mental model.
**Cons**: Forces migration on every existing customer in a fixed window; no answer for GHES; removes break-glass.
**Reason for rejection**: Migration cost outweighs the simplification, and we genuinely need PAT for GHES.

### Alternative 4: Use GitHub OAuth User-to-Server Flow Instead of an App

**Description**: Use OAuth to obtain `ghu_*` user-to-server tokens; act on the user's behalf.
**Pros**: No separate bot identity to register.
**Cons**: PR authorship still attributes to the human user — defeats the entire motivating workflow win. Token scoping is also coarser.
**Reason for rejection**: Doesn't solve the author-identity problem, which is half the reason we're doing this.

## Trade-offs and Consequences

### Positive Consequences

- **Human approval workflows function correctly.** CODEOWNERS, "require non-author review," and similar branch-protection gates work as advertised because bot ≠ human.
- **Cleaner audit trail.** Bot-authored PRs and commits separate cleanly from human work in `git log` and on the PR list.
- **Better rate limits.** Per-installation quota, scales with installed repo count.
- **Granular revocation.** Customers uninstall Paid from a single repo, not by revoking a token they may use elsewhere.
- **Unified GitHub presence.** One `paid-agents` GitHub App identity for repo writes, aligned closely with the existing `paid-code-reviewer` app model instead of "PAT plus paid-code-reviewer."
- **Reduces ad-hoc bot heuristics.** Stable author login lets us simplify several `scan_paid_prs_activity.rb` allowlists.

### Negative Consequences

- **Two credential paths to maintain.** Resolver indirection helps but doesn't make the duplication free.
- **Token-cache complexity.** Installation tokens are 1-hour and minted per-repo; we add a cache, invalidation, and a "what if cache is stale during a long-running activity" failure mode.
- **App-manifest UX.** Self-hosted bootstrap is a real new flow with its own surface area to test.
- **Org admin coordination.** Customers whose GitHub org admin restricts third-party apps need an admin to approve installation — a new friction point.

### Risks and Mitigations

- **Risk**: Installation token cache returns expired tokens during a long-running container session.
  **Mitigation**: TTL of 50 minutes (10-minute safety margin against GitHub's 60); 401-from-GitHub triggers a forced re-mint; container-side calls go through the secrets proxy (RDR-006), which can refresh transparently.
- **Risk**: Customer's GitHub org has third-party-app restrictions; install request hangs.
  **Mitigation**: Detect the "approval required" state from the install callback; surface explicit messaging; keep PAT path available so they aren't blocked.
- **Risk**: Self-hoster's manifest-flow registration writes a malformed private key into credentials.
  **Mitigation**: Validate the RSA key parses (mirroring `ReviewBotInstallationToken#rsa_private_key`) before persisting; surface a clear error if not.
- **Risk**: App suspended or uninstalled mid-workflow.
  **Mitigation**: Webhook subscription to `installation.suspend` / `installation.deleted` events updates `GithubInstallation` state; in-flight workflows surface a clear "Paid lost access to this repo" error rather than retry-looping.
- **Risk**: PR authored by `paid-agents[bot]` triggers customer CI rules that whitelist humans only.
  **Mitigation**: Documented during install ("Paid will appear as `paid-agents[bot]` on PRs — update CI allowlists"); we cannot fix this for them but we can warn.
- **Risk**: Existing `BOT_LOGIN` allowlists in `scan_paid_prs_activity.rb` confuse the new bot author with a reviewer bot.
  **Mitigation**: Audit and split the lists explicitly — author-bot vs reviewer-bot. Add specs covering the case where the same `[bot]` slug appears as both author and reviewer (unlikely but possible if a self-hoster names them identically).

## Implementation Plan

### Prerequisites

- [ ] Decide whether `paid-agents` is the canonical app slug and register the App with required permissions enumerated below.
- [ ] Mint and store the canonical app's private key in Rails credentials.
- [ ] Confirm webhook ingress story for SaaS (does Paid expose a public webhook endpoint, or do we keep polling and use webhooks only opportunistically?).

### Required GitHub App Permissions

Repository:

- Contents: read & write (push branches, read files)
- Pull requests: read & write (open, comment, label, request review, merge)
- Issues: read & write (read trigger labels, comment, label)
- Metadata: read (mandatory, default)
- Checks: read (read CI status for auto-merge gates)
- Workflows: write (only if we ever modify `.github/workflows/*` — keep off until needed)
- Commit statuses: read

Organization:

- Members: read (for CODEOWNERS resolution)

Subscribe to events: `installation`, `installation_repositories`, `pull_request`, `pull_request_review`, `issues`, `issue_comment`.

### Step-by-Step

#### Step 1 — App registry + token minting

- Add `Github::AppRegistry` (mirrors `ReviewBotInstallationToken` config pattern).
- Add `Github::AppJwt.sign(app_id:, private_key:)` extracted from `ReviewBotInstallationToken#app_jwt`.
- Add `Github::AppInstallation.token_for(installation_id:, repo_full_name:)` with cache.
- Refactor `Github::ReviewBotInstallationToken` to delegate JWT signing to `AppJwt` (deduplication, no behavior change).

#### Step 2 — Models & migration

- `rails generate migration CreateGithubInstallations` with columns above; add unique index on `(account_id, github_installation_id)`.
- `rails generate migration AddGithubInstallationToProjects` adding `github_installation_id` (nullable FK) and a `CHECK` constraint enforcing exactly one of `github_installation_id` / `github_token_id`.
- Update `Project` with the validations and the `github_credential` / `github_author_login` methods.

#### Step 3 — Install flow

- `GET /github_app/install` — redirects to `https://github.com/apps/<slug>/installations/new?state=<csrf>`.
- `GET /github_app/callback` — handles `installation_id` + `setup_action` query params, persists `GithubInstallation`, redirects to project picker.
- `POST /webhooks/github_app` — handles `installation`, `installation_repositories`, `installation.suspend`, `installation.deleted` to keep `GithubInstallation` in sync.
- Admin-only `/admin/github_app/setup` for self-hosters: app-manifest creation + credential persistence.

#### Step 4 — Activity / service rewiring

- Anywhere we call `project.github_token.token` or `project.github_token.client`, replace with `project.github_credential` returning an opaque token, then `GithubClient.new(token: project.github_credential)`.
- Update the secrets proxy to resolve credentials via `project.github_credential` instead of reading `github_token` directly.

#### Step 5 — Bot-login awareness

- `Github::AppRegistry.bot_login` is the authoritative app-bot identity.
- Update `scan_paid_prs_activity.rb` allowlists: split `author_bot_logins` (App slug) from `reviewer_bot_logins` (review bot, copilot, codex, etc.). Drop heuristics that the new author identity makes redundant.

#### Step 6 — UI

- Project create form: "How should Paid authenticate to GitHub?" → App install (recommended) | PAT.
- Existing-project settings: migration banner offering App install when PAT is in use.

### Files to Create/Modify

**Create**:

- `app/services/github/app_registry.rb`
- `app/services/github/app_jwt.rb`
- `app/services/github/app_installation.rb`
- `app/models/github_installation.rb`
- `app/controllers/github_app/installations_controller.rb`
- `app/controllers/webhooks/github_app_controller.rb`
- `app/controllers/admin/github_app/setup_controller.rb`
- `db/migrate/<ts>_create_github_installations.rb`
- `db/migrate/<ts>_add_github_installation_to_projects.rb`
- Specs for each.

**Modify**:

- `app/services/github/review_bot_installation_token.rb` (delegate JWT signing to `AppJwt`)
- `app/models/project.rb` (credential resolver, validation)
- `app/controllers/api/github_proxy_controller.rb` (resolve via project credential)
- `app/temporal/activities/scan_paid_prs_activity.rb` (split author-bot vs reviewer-bot logins)
- All activities currently calling `project.github_token` (route through resolver)
- `docs/rdrs/RDR-012-github-integration.md` (cross-link this RDR in the Notes section)

### Dependencies

- No new gems. Existing `octokit`, `faraday`, `openssl` are sufficient (same stack `ReviewBotInstallationToken` already uses).

## Validation

### Testing Approach

1. **Unit**: `AppJwt`, `AppRegistry`, `AppInstallation` token caching/refresh, `Project#github_credential` resolution, exactly-one-credential validation.
2. **Integration**: Install callback persists `GithubInstallation`; uninstall webhook marks it revoked; suspend webhook flips a flag without deleting.
3. **End-to-end**: Open a PR through both code paths (App + PAT) against a sandbox repo; assert author is `<slug>[bot]` for App path and the human user for PAT path.
4. **Migration**: Existing PAT projects continue to function unchanged after migration runs.

### Test Scenarios

1. **Project with App credential opens a PR** → PR author is `paid-agents[bot]`; CODEOWNERS approval-from-other gates fire correctly.
2. **Project with PAT opens a PR** → PR author is the PAT user (unchanged behavior).
3. **Token cache expires mid-activity** → resolver mints a fresh token; activity continues without surfacing an error.
4. **Customer uninstalls app** → next activity using that installation fails clearly with "Paid no longer has access"; no silent retry loop.
5. **Self-hoster runs manifest flow** → admin completes the flow; `AppRegistry.configured?` flips to true; new projects offer App auth.
6. **Project misconfigured with both PAT and installation** → validation rejects.
7. **GHES customer** → manifest flow registers their own app or they fall back to PAT.

### Performance Validation

- Installation token mint <500ms (single API call after JWT sign).
- Cache hit ratio >95% steady-state (TTL 50min, typical activity bursts well under that).
- No measurable latency regression on PR creation vs PAT path.

### Security Validation

- App private key encrypted at rest (Rails credentials or env var, never DB).
- Installation tokens never logged.
- Webhook signature validation on `/webhooks/github_app`.
- Manifest-flow callback validates state/CSRF.
- Tenant isolation: `GithubInstallation.account_id` enforced through RLS like other tenant-scoped tables.

## References

### Related RDRs

- [RDR-012](RDR-012-github-integration.md) — Original GitHub integration; this RDR extends the auth model.
- [RDR-006](RDR-006-secrets-proxy.md) — How agents receive credentials.
- [RDR-022](RDR-022-auto-merge-pr-strategy.md) — Auto-merge gates that benefit from a stable bot author identity.

### External

- [GitHub Apps documentation](https://docs.github.com/en/apps)
- [Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [Registering a GitHub App from a manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)

### Internal Reference

- [`app/services/github/review_bot_installation_token.rb`](../../app/services/github/review_bot_installation_token.rb) — working installation-token pattern.
- [`app/models/github_token.rb`](../../app/models/github_token.rb) — current PAT model.
- [`app/models/project.rb`](../../app/models/project.rb) — current project ↔ token binding.

## Notes

- After this RDR is implemented, RDR-012's "PAT vs GitHub App" section should be annotated to point here for the auth decision while the polling/caching/Projects-V2 decisions remain authoritative.
- Webhook ingress is out of scope for this RDR — assume polling stays in place and webhooks are an opportunistic optimization. If we add webhook-driven event ingestion, that's a follow-up RDR.
- The `paid-code-reviewer` App stays distinct for now (different scopes, different identity, separate review surface). Future consolidation into a single `paid-agents` App with both review and write permissions is possible but not in scope here.
