# frozen_string_literal: true

module ConfigurationProfiles
  # Configures Paid for a single user who wants Paid to handle issues end to
  # end with minimal supervision. Touches user settings (auto-pick,
  # permissive labels, agent styles) and tenant settings (high concurrency
  # budgets). Skips project-level overrides — that posture is the caller's
  # project-level decision.
  class SoloFullyAutomatedProfile < Profile
    OVERRIDE_KEYS = %i[
      run_concurrency_mode
      max_concurrent_runs
      default_poll_interval_seconds
      auto_pick_skip_labels
      max_tokens_per_run
    ].freeze

    id "solo_fully_automated"
    display_name "Solo Fully Automated"
    description "Configure Paid to pick up issues and ship PRs end-to-end without supervision. " \
                "Best for solo developers who want maximum automation."
    levels :user, :tenant

    def self.build_plan(user:, project: nil, project_id: nil, overrides: {})
      current_user_settings = current_user_settings(user)
      current_tenant = current_tenant_setting(user)

      overrides = (overrides || {}).symbolize_keys
      unknown_keys = overrides.keys - OVERRIDE_KEYS
      if unknown_keys.any?
        raise ArgumentError, "SoloFullyAutomatedProfile does not accept overrides: #{unknown_keys.inspect}"
      end

      user_after = {
        run_concurrency_mode: "auto",
        max_concurrent_runs: 5,
        default_poll_interval_seconds: 60,
        auto_pick_skip_labels: [ "needs-design", "blocked-external" ]
      }.merge(overrides.slice(:run_concurrency_mode, :max_concurrent_runs,
        :default_poll_interval_seconds, :auto_pick_skip_labels))

      tenant_after = {
        max_concurrent_runs: 10,
        max_tokens_per_run: 25_000_000
      }.merge(overrides.slice(:max_concurrent_runs, :max_tokens_per_run))

      changes = []
      changes << {
        level: :user,
        attribute: "user_settings.run_concurrency_mode",
        before: current_user_settings.run_concurrency_mode,
        after: user_after[:run_concurrency_mode]
      }
      changes << {
        level: :user,
        attribute: "user_settings.max_concurrent_runs",
        before: current_user_settings.max_concurrent_runs,
        after: user_after[:max_concurrent_runs]
      }
      changes << {
        level: :user,
        attribute: "user_settings.default_poll_interval_seconds",
        before: current_user_settings.default_poll_interval_seconds,
        after: user_after[:default_poll_interval_seconds]
      }
      changes << {
        level: :user,
        attribute: "user_settings.auto_pick_skip_labels",
        before: current_user_settings.auto_pick_skip_labels,
        after: user_after[:auto_pick_skip_labels]
      }
      changes << {
        level: :tenant,
        attribute: "tenant_settings.max_concurrent_runs",
        before: current_tenant.max_concurrent_runs,
        after: tenant_after[:max_concurrent_runs]
      }
      changes << {
        level: :tenant,
        attribute: "tenant_settings.max_tokens_per_run",
        before: current_tenant.max_tokens_per_run,
        after: tenant_after[:max_tokens_per_run]
      }

      Plan.new(
        profile_id: id,
        project_id: project_id,
        changes: changes,
        prerequisites: [
          {
            key: "github_app_installed",
            description: "At least one GitHub App installation must be connected to the account"
          }
        ],
        questions: [
          {
            key: "max_concurrent_runs",
            prompt: "How many concurrent agent runs should be allowed?",
            default: 5
          }
        ]
      )
    end
  end
end
