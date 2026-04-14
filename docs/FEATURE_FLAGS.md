# Feature Flags

Paid uses Flipper-backed runtime flags only for staged behavior rollouts where replacing the old path in one deploy would be risky. Flags are temporary rollout controls, not a compatibility layer.

## Definition checklist

Every flag must be registered in `app/services/feature_flags.rb` with:

- `owner`
- `intent`
- `rollout_plan`
- `cleanup_criteria`

The first shipped flag is `explicit_pr_automation_decisions`, which exists to stage the PR automation decision refactor for issue `#1077`.

## House pattern

Rails code and Temporal activities should query flags through `FeatureFlags`, never through raw Flipper string lookups:

```ruby
FeatureFlags.explicit_pr_automation_decisions?(project: project)
FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: project)
```

Temporal workflows must stay deterministic, so they should not read Flipper directly. Use the workflow helper, which snapshots flags through `Activities::LoadFeatureFlagsActivity`:

```ruby
feature_flag_enabled?(:explicit_pr_automation_decisions, project_id: project_id)
```

## Enablement

List current state:

```bash
bundle exec rake feature_flags:list
bundle exec rake feature_flags:list PROJECT_ID=123
```

Enable or disable intentionally:

```bash
bundle exec rake "feature_flags:enable[explicit_pr_automation_decisions]" PROJECT_ID=123
bundle exec rake "feature_flags:disable[explicit_pr_automation_decisions]" PROJECT_ID=123
```

Omit `PROJECT_ID=123` to change the global flag state. Use the Paid project id, not `owner/repo`, because the same GitHub repository can exist in multiple accounts.

## Issue convention

When a rollout uses a flag:

1. The umbrella issue defines the flag and rollout intent.
2. The implementation issue/PR ships the new behavior behind that flag.
3. Separate enablement work tracks which projects or repos should be opted in.
4. Cleanup work removes the flag definition and the old path as soon as the rollout is complete.
