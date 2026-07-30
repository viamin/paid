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
            message: "Auto-merge is enabled but owner reviewer login is blank."
          )
        end
      end
    end
  end
end
