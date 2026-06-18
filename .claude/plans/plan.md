# Plan: Address review feedback on PR #2617

## Branch
`paid/2592-fixrunners-opencode-minimax-configured-with-non-ex-02d565`

## Review Threads to Address

Three unresolved review threads need code changes:

### Thread 1 — `app/models/runner.rb:1325` — inconsistent error message

The validation message at line 1325 mixes the raw internal provider string
(`model.provider`, e.g. `"minimax"`) with a human-readable label produced by
`RunnerSupport.api_service_type_label(expected_provider)`. Both sides should
use the same representation so the message reads consistently.

**Fix**: Replace `model.provider` with `RunnerSupport.api_service_type_label(model.provider)`.

```ruby
errors.add(:config, "#{direct_outbound_runner_label} model belongs to the #{RunnerSupport.api_service_type_label(model.provider)} catalog but expected #{RunnerSupport.api_service_type_label(expected_provider)}")
```

### Thread 2 — `spec/factories/runners.rb:40` — duplicated `after(:build)` block

The `after(:build)` blocks in `spec/factories/runners.rb` (lines 25–41) and
`spec/factories/providers.rb` (lines 24–40) are byte-for-byte identical except
for the local variable name. Extract the seeding logic into
`KnownDirectOutboundModels` so both factories share a single implementation.

**Fix**:

1. Add `KnownDirectOutboundModels.seed_from_direct_outbound_config(record)` to
   `spec/support/known_direct_outbound_models.rb`. The helper inspects
   `record.runner_key`, derives the direct-outbound config key (opencode,
   kilocode, pi), and seeds the matching LlmModel row when api_provider +
   model are present. Returns early (no-op) for unsupported runner_keys.
2. Replace both `after(:build)` blocks with a single call to that helper.

The variable `runner`/`provider` distinction is dropped — both factories pass
the same record shape (a record with `runner_key`, `config`, and either a
provider_api_key built into the factory or unrelated).

### Thread 3 — `spec/support/known_direct_outbound_models.rb:43` — provider-prefixed model id lookup

`CATALOG` is keyed on bare model ids (e.g. `"MiniMax-M3"`), but when an
OpenCode runner is configured with a provider-qualified model id like
`"minimax/MiniMax-M3"`, the factory's `after(:build)` passes the raw config
value — `"minimax/MiniMax-M3"` — directly to `seed_catalog_model`. That
qualified key does not exist in `CATALOG`, so the lookup silently returns
`nil` and no `LlmModel` row is created. A test that relies on factory
auto-seeding for a qualified model id will hit a validation failure with no
obvious explanation.

**Fix**: Strip the provider prefix before the CATALOG lookup in
`seed_catalog_model`. The factory always passes the raw config value, so the
helper must accept qualified model ids and try the bare form as well.

```ruby
def seed_catalog_model(api_provider:, model_id:)
  raw = model_id.to_s
  bare_id = raw.include?("/") ? raw.split("/", 2).last : raw
  provider = CATALOG[[ api_provider.to_s, bare_id ]] || CATALOG[[ api_provider.to_s, raw ]]
  return nil if provider.blank?

  seed_model(model_id: bare_id, provider: provider)
end
```

This matches the validation's lookup behavior in
`Runner#direct_outbound_catalog_model_id_candidates` (which already
de-qualifies a model id whose prefix matches the runner's
`opencode_model_provider`), so the factory now seeds the same row the
validation would resolve.

## Proactive scan — same-class issues elsewhere in the diff

- The `RunnerSupport.api_service_type_label` change at line 1325 is the only
  spot where `model.provider` is interpolated raw into a user-facing
  message. Searched all changed files; nothing similar remains.
- `after(:build)` duplication only exists between `runners.rb` and
  `providers.rb` factories. No other factories (e.g. project, account) seed
  LlmModel rows from a `config` hash, so the extracted helper covers the
  only two call sites.
- The provider-prefix issue could also affect seeded test fixtures created
  via the smoke helpers, but those call `KnownDirectOutboundModels.seed_model`
  directly with already-bare model ids from `scenario.default_model` (e.g.
  `"MiniMax-M2.7"`, `"moonshotai/kimi-k2-0905"`) — so they don't hit
  `seed_catalog_model` and don't need the prefix-stripping fix.

## Files I will change

- `app/models/runner.rb` (line 1325 — one-line message fix)
- `spec/support/known_direct_outbound_models.rb`
  (add `seed_from_direct_outbound_config`, prefix-strip in
  `seed_catalog_model`)
- `spec/factories/runners.rb` (collapse `after(:build)` to helper call)
- `spec/factories/providers.rb` (collapse `after(:build)` to helper call)

## Verification steps

1. `bundle install` (and `yarn install` if needed)
2. `bin/rails db:prepare`
3. `bundle exec rubocop` on the changed files (run full `bundle exec rubocop`
   before commit)
4. `bundle exec rspec spec/models/runner_spec.rb spec/models/agent_run_spec.rb spec/requests/agent_runs_spec.rb spec/factories` — at minimum these
   exercise the changed code paths
5. `bundle exec rspec` (full suite) if time permits

## Commit

Single commit with conventional subject:

```
fix(runners): address reviewer feedback on catalog-validation messages and fixtures
```

No push. The PR branch already carries the prior fix commits; this stacks on
top.
