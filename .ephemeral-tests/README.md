# Ephemeral PR Tests

One-off system/integration tests that live **only on PR branches**. They run
in CI for the PR but are not merged to `main`.

## When to use this

- Complex multi-step scenarios that only need to run once for a specific change
- Exploratory integration tests that validate a new feature end-to-end
- Tests that are too slow, brittle, or specialized for the permanent suite
- Validating a migration path or data transformation before merge

## How it works

1. Add `*_spec.rb` (RSpec/Capybara) files to `.ephemeral-tests/` as part
   of your PR. (Playwright/JS support may be added later.)
2. CI detects the files and runs the ephemeral test job automatically.
3. Results are posted as a PR comment.
4. When the PR merges, the test files don't land on `main` — they exist only
   on the PR branch.

## Security

- **Same-repo PRs only.** Fork PRs are excluded — tests never execute for
  external contributions.
- **Minimal permissions.** The job has `contents: read`, `checks: write`,
  and `pull-requests: write` (for posting result comments) only.
- **Standard frameworks only.** Tests run through RSpec, not arbitrary scripts.

## Example

```ruby
# .ephemeral-tests/multi_agent_orchestration_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Multi-agent orchestration", type: :system do
  it "runs two agents in sequence and merges both results" do
    # ... your one-off test ...
  end
end
```

## Cleanup

No cleanup is needed. Tests live on the PR branch and are discarded when the
branch is deleted after merge. If you want to keep a test permanently, move it
to `spec/system/` or `spec/integration/` before merging.
