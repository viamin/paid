# frozen_string_literal: true

module Automation
  module Configuration
    # Auto-continue automation configuration for a project. Auto-continue
    # runs today have no dedicated project-level toggle — scanning only
    # triggers for active (non-paused) issues — so this value object
    # captures the behaviour enabled by the project-scope automation flags.
    #
    # +auto_scan_prs+ gates PR scanning; when scanning is off, auto-continue
    # cannot observe PRs. Strategy code should consult
    # {AutoContinue#enabled?} instead of reading +project.auto_scan_prs+
    # directly so future gates (rate limits, provider toggles, etc.) can be
    # added without touching callers.
    class AutoContinue < ::Data.define(:enabled)
      def self.from_project(project)
        new(enabled: project.auto_scan_prs == true)
      end

      def enabled? = enabled == true
    end
  end
end
