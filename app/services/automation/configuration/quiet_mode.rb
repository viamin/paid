# frozen_string_literal: true

module Automation
  module Configuration
    # Project-level delivery preference for GitHub commentary.
    class QuietMode < ::Data.define(:enabled)
      def self.from_project(project)
        new(enabled: project.quiet_mode == true)
      end

      def enabled? = enabled == true
    end
  end
end
