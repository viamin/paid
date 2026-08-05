# frozen_string_literal: true

module Interop
  class ExternalAgentLidContract
    # @spec LID-RUNS-006
    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      {
        configured: lid_mode.present?,
        mode: lid_mode,
        overridden: project.lid_mode_overridden?,
        detection: detection,
        workflow_contract: workflow_contract,
        planning: planning_contract
      }
    end

    private

    attr_reader :project

    def lid_mode
      @lid_mode ||= project.lid_mode.to_s.presence
    end

    def detection
      metadata = project.lid_detection.is_a?(Hash) ? project.lid_detection.deep_stringify_keys : {}

      {
        "version" => metadata["version"],
        "detected_at" => metadata["detected_at"],
        "sources" => Array(metadata["sources"]),
        "warnings" => Array(metadata["warnings"]),
        "scope_defaults_to_in_scope" => metadata["scope_defaults_to_in_scope"] == true
      }
    end

    def workflow_contract
      {
        implementation_prompt: Lid::InjectIntoPrompt.section_for(project: project),
        coherence_check_behavior: "soft_block_reported_in_pr"
      }
    end

    def planning_contract
      {
        trigger_goal: "lid_planning",
        trigger_via: "trigger_agent_run",
        can_start_from_external_agent: true,
        named_plan_docs_supported: true,
        planning_pr_correction_supported: false
      }
    end
  end
end
