# frozen_string_literal: true

module Automation
  module Configuration
    # Auto-pick automation configuration for a project. Currently wraps the
    # +auto_pick_enabled+ toggle; future extensions (provider selection
    # override, per-tier caps) should live here so strategy code stops
    # reaching into Project columns directly.
    class AutoPick < ::Data.define(:enabled)
      def self.from_project(project)
        new(enabled: project.auto_pick_enabled == true)
      end

      def enabled? = enabled == true
    end
  end
end
