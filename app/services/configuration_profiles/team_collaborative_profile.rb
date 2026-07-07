# frozen_string_literal: true

module ConfigurationProfiles
  # Configures Paid for a team that wants slow, supervised agent runs with a
  # single concurrent run per project. Touches user settings (skip labels,
  # concurrency caps) and tenant settings (concurrency budget).
  #
  # Note: `auto_pick_skip_labels` is an *exclusion* list (see
  # AutoPickSkipLabels / Automation::Strategies::AutoPick::DefaultCandidateSource)
  # -- issues carrying the label are skipped by auto-pick, but unlabeled
  # issues are still auto-picked. Paid has no positive allow/gate mechanism
  # today (i.e. no way to require a label before an issue becomes
  # auto-pickable), so this profile does not claim to "gate" automation
  # behind a label -- it only excludes issues that are explicitly flagged
  # as awaiting human review.
  class TeamCollaborativeProfile < Profile
    id "team_collaborative"
    display_name "Team Collaborative"
    description "Slow, supervised agent runs that pair with human review. Best for teams " \
                "that want to exclude issues awaiting review from auto-pick."
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
        ]
      )
    end
  end
end
