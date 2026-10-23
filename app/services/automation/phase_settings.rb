# frozen_string_literal: true

module Automation
  # RDR-077 §2: project phase defaults. A project without stored settings
  # derives them from its currently effective capabilities so nothing changes
  # for existing projects, and a disabled phase keeps every subordinate
  # capability value it was configured with.
  #
  # @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-016
  class PhaseSettings
    SETTINGS_KEY = "automation_phase_settings"
    PHASES_KEY = "phases"
    RELEASE_KEY = "release"
    DEPLOYMENT_KEY = "deployment"

    def self.call(...)
      new(...).call
    end

    # Read accessors for callers that need one predicate without holding the
    # settings object (queue filters, background jobs).
    def self.phase_enabled?(project, phase)
      call(project).phase_enabled?(phase)
    end

    def initialize(project)
      @project = project
    end

    def call
      self
    end

    def configured?
      flags = raw_settings[PHASES_KEY]
      (flags.is_a?(Hash) && flags.any?) || raw_settings.key?(RELEASE_KEY) || raw_settings.key?(DEPLOYMENT_KEY)
    end

    # @spec AUTOMATION-PHASES-002
    def phase_enabled?(phase)
      return phase_flags[phase.to_s] ? true : false if phase_flags.key?(phase.to_s)

      false
    end

    def phases
      Automation::Phases::ALL.index_with { |phase| phase_enabled?(phase) }
    end

    # Release and deployment are separate subordinate controls: enabling one
    # never enables the other.
    # @spec AUTOMATION-PHASES-016
    def release_enabled?
      settings[RELEASE_KEY] ? true : false
    end

    def deployment_enabled?
      settings[DEPLOYMENT_KEY] ? true : false
    end

    # Turning a phase off retains every subordinate value, so the returned
    # hash always carries the complete phase map.
    def to_h
      {
        PHASES_KEY => phases,
        RELEASE_KEY => release_enabled?,
        DEPLOYMENT_KEY => deployment_enabled?
      }
    end

    # Serialized shape stored on the project.
    def to_settings
      to_h
    end

    # Derived defaults for projects that predate the phase model. Every
    # currently effective capability stays in the phase it occupied before, and
    # nothing new is enabled.
    # @spec AUTOMATION-PHASES-015
    def derive
      {
        PHASES_KEY => {
          Automation::Phases::DISCOVERY => true,
          Automation::Phases::ISSUE_PREPARATION => project.auto_enhance_enabled?,
          Automation::Phases::CODING => coding_automation?,
          Automation::Phases::MERGE => merge_automation?,
          Automation::Phases::RELEASE_DEPLOYMENT => release_automation?,
          Automation::Phases::OPERATIONS => false
        },
        RELEASE_KEY => release_automation?,
        DEPLOYMENT_KEY => false
      }
    end

    private

    attr_reader :project

    def raw_settings
      value = project[SETTINGS_KEY]
      value.is_a?(Hash) ? value : {}
    end

    def settings
      @settings ||= configured? ? raw_settings : derive
    end

    def phase_flags
      flags = settings[PHASES_KEY]
      flags.is_a?(Hash) ? flags : {}
    end

    def coding_automation?
      project.auto_pick_enabled? || project.auto_scan_prs == true ||
        project.auto_scan_security == true || project.auto_fix_merge_conflicts == true
    end

    def merge_automation?
      project.auto_merge_enabled? || project.auto_merge_mode.to_s != "off"
    end

    def release_automation?
      project.auto_release_granularity.to_s != "off"
    end
  end
end