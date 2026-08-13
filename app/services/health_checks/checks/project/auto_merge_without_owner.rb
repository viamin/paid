# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class AutoMergeWithoutOwner < HealthChecks::Check
        self.scope = :project

        def self.network? = false

        def call
          return [] unless subject.auto_merge_enabled?
          return [] if subject.owner_reviewer_login.present?

          finding(
            severity: :error,
            title: "Auto-merge enabled without an owner reviewer",
            description: "Auto-merge is on but no owner reviewer login is set, so human-authored PRs can never satisfy owner approval and will stall.",
            remediation: "Set an owner reviewer login (a trusted GitHub username) or turn off auto-merge.",
            action_url: settings_action_url(:edit_project_path, anchor: "owner-reviewer")
          )
        end
      end
    end
  end
end
