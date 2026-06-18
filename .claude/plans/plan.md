# Plan: Address unresolved review threads on PR #2617

## Branch
`paid/2592-fixrunners-opencode-minimax-configured-with-non-ex-02d565`

## Status check

Three of the four review threads from PR #2617 are **not yet applied**:

| Thread | File | Status |
|---|---|---|
| 1 — remove `.claude/plans/plan.md` and add to `.gitignore` | `.claude/plans/plan.md`, `.gitignore` | not applied |
| 2 — `Runner#direct_outbound_config_models_must_exist_in_catalog` error message uses raw `model.provider` on left, `RunnerSupport.api_service_type_label` on right | `app/models/runner.rb:1325` | not applied |
| 3 — `seed_catalog_model` doesn't strip provider prefix before CATALOG lookup, so OpenCode factories passing `"minimax/MiniMax-M3"` silently miss | `spec/support/known_direct_outbound_models.rb:38-43` | not applied |
| 4 — `after(:build)` blocks in `spec/factories/runners.rb` and `spec/factories/providers.rb` are byte-for-byte identical except for the loop variable | `spec/factories/runners.rb:25-41`, `spec/factories/providers.rb:24-40` | not applied |

I verified each one against the working tree and the diff vs `main`.

## Changes I will make

### 1. `.claude/plans/` and `.gitignore`

- `git rm` `.claude/plans/plan.md`
- Add `.claude/plans/` (and `.claude/settings.json.paid-state-*` for completeness) to `.gitignore`. Actually, the tracked state files `.claude/settings.json`, `.claude/settings.json.paid-state-*/backup`, `.claude/settings.json.paid-state-*/state`, `.claude/statusline-command.sh` are already tracked, so the new entry is scoped to `plans/` only.

### 2. `app/models/runner.rb:1325`

Replace `#{model.provider}` with `#{RunnerSupport.api_service_type_label(model.provider)}` so both halves of the message use the same label form.

```ruby
errors.add(:config, "#{direct_outbound_runner_label} model belongs to the #{RunnerSupport.api_service_type_label(model.provider)} catalog but expected #{RunnerSupport.api_service_type_label(expected_provider)}")
```

### 3. `spec/support/known_direct_outbound_models.rb`

In `seed_catalog_model`, strip any `provider/` prefix before the `CATALOG` lookup, mirroring the validation's `direct_outbound_catalog_model_id_candidates`. Use the bare id when seeding the `LlmModel` row (because `LlmModel#model_id` is the catalog identifier, not the runner-side qualified string).

```ruby
def seed_catalog_model(api_provider:, model_id:)
  raw = model_id.to_s
  bare_id = raw.include?("/") ? raw.split("/", 2).last : raw
  provider = CATALOG[[ api_provider.to_s, bare_id ]] || CATALOG[[ api_provider.to_s, raw ]]
  return nil if provider.blank?

  seed_model(model_id: bare_id, provider: provider)
end
```

### 4. Extract shared `after(:build)` into `KnownDirectOutboundModels.seed_from_direct_outbound_config`

Add a module function to `KnownDirectOutboundModels`:

```ruby
def seed_from_direct_outbound_config(record)
  config_key, api_provider_key, model_key = case record.runner_key
  when "opencode" then [ "opencode", "api_provider", "model" ]
  when "kilocode" then [ "kilocode", "api_provider", "model" ]
  when "pi" then [ "pi", "api_provider", "model" ]
  else return
  end

  config = record.config.is_a?(Hash) ? record.config[config_key] : nil
  return unless config.is_a?(Hash)

  api_provider = config[api_provider_key].to_s
  model_id = config[model_key].to_s
  return if api_provider.blank? || model_id.blank?

  seed_catalog_model(api_provider: api_provider, model_id: model_id)
end
```

Then collapse the two factory `after(:build)` blocks to:

```ruby
after(:build) { |record| KnownDirectOutboundModels.seed_from_direct_outbound_config(record) }
```

The `Provider` factory also has a `runner_key` attribute (it inherits the runner-key semantics via shared columns), so the same helper works for both.

## Proactive scan — same-class issues elsewhere

After making the changes, I will scan the full diff for similar problems:

- Any other place in the diff that interpolates a raw provider string (e.g. `model.provider`, internal `service_type`) into a user-facing message without going through `api_service_type_label`. I will fix any such inconsistency.
- Any other place in the diff where `seed_catalog_model` (or a similar lookup) is called with a qualified model id and the lookup might miss. The smoke helpers in `provider_smoke_helpers.rb:274` and `runner_smoke_helpers.rb:304` call `seed_model` directly with already-bare ids from `scenario.default_model` (e.g. `"MiniMax-M2.7"`, `"moonshotai/kimi-k2-0905"`), so they don't need the prefix-strip change.
- Any other duplicated blocks between `runners.rb` and `providers.rb` factories. I checked — the two factories are otherwise identical (modulo `runner_key` vs `provider_key` in the base attribute name), and only the `after(:build)` block is duplicated.
- Any places I should also strip the prefix. `Runner#direct_outbound_catalog_model_id_candidates` already de-qualifies a model id whose prefix matches `opencode_model_provider`, so the test seeded via the fixed helper will resolve the same row.

## Files I will change

- `.gitignore` (add `.claude/plans/`)
- `app/models/runner.rb` (one-line message fix)
- `spec/support/known_direct_outbound_models.rb` (extract helper, prefix-strip)
- `spec/factories/runners.rb` (collapse `after(:build)`)
- `spec/factories/providers.rb` (collapse `after(:build)`)

Files removed: `.claude/plans/plan.md`.

## Verification steps

1. `bundle install`
2. `bin/rails db:prepare`
3. `bundle exec rubocop` on the changed files
4. `bundle exec rspec spec/models/runner_spec.rb spec/models/agent_run_spec.rb spec/requests/agent_runs_spec.rb` — covers all the validation paths and the factory-driven seeding
5. `bundle exec rspec` if time permits

## Commit

Single commit, conventional subject:

```
fix(runners): address reviewer feedback on catalog-validation messages and fixtures
```

No push.
