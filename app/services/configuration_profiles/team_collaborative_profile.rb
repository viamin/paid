# frozen_string_literal: true

module ConfigurationProfiles
  # Configures Paid for a team that wants agent runs gated behind a
  # per-project label and a single concurrent run per project. Touches
  # user settings (gating labels, concurrency caps) and tenant settings
  # (concurrency budget).
  class TeamCollaborativeProfile < Profile
    id "team_collaborative"
    display_name "Team Collaborative"
    description "Slow, supervised agent runs that pair with human review. Best for teams " \
                "that want to gate automation behind explicit labels."
    levels :user, :tenant

    def self.build_plan(user:, project: nil, project_id: nil, overrides: {})
      current_user_settings = current_user_settings(user)
      current_tenant = current_tenant_setting(user)
      overrides = (overrides || {}).symbolize_keys

      changes = []
      changes << {
        level: :user,
        attribute: "user_settings.run_concurrency_mode",
        before: current_user_settings.run_concurrency_mode,
        after: "manual"
      }
      changes << {
        level: :user,
        attribute: "user_settings.max_concurrent_runs",
        before: current_user_settings.max_concurrent_runs,
        after: 1
      }
      changes << {
        level: :user,
        attribute: "user_settings.auto_pick_skip_labels",
        before: current_user_settings.auto_pick_skip_labels,
        after: [ "needs-review" ]
      }
      changes << {
        level: :tenant,
        attribute: "tenant_settings.max_concurrent_runs",
        before: current_tenant.max_concurrent_runs,
        after: 3
      }

      Plan.new(
        profile_id: id,
        project_id: project_id,
        changes: changes,
        prerequisites: [
          { key: "github_app_installed", description: "GitHub App must be installed" }
        ],
        questions: [
          { key: "gate_label", prompt: "Which label should gate auto-pick?", default: "agent-ready" }
        ]
      )
    end
  end
end
