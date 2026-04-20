# frozen_string_literal: true

module Automation
  module Configuration
    # Auto-merge automation configuration for a project. Wraps the
    # +auto_merge_mode+ setting, the selected merge method (squash /
    # merge / rebase), and the +auto_fix_merge_conflicts+ follow-up flag.
    class AutoMerge < ::Data.define(:enabled, :merge_method, :fix_merge_conflicts)
      def self.from_project(project)
        new(
          enabled: project.auto_merge_enabled?,
          merge_method: project.merge_method,
          fix_merge_conflicts: project.auto_fix_merge_conflicts == true
        )
      end

      def enabled? = enabled == true
      def fix_merge_conflicts? = fix_merge_conflicts == true
    end
  end
end
