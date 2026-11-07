# frozen_string_literal: true

module Automation
  module ProjectDelegation
    # Shared read model for settings, Inbox, API, and MCP surfaces.
    # Exposes delegation-aware authorization decisions through EffectivePolicy,
    # eliminating local inference from labels, stale approval, or queue state.
    # @spec PROJECT-DELEGATION-005
    class Projection
      def self.call(...)
        new(...).call
      end

      def initialize(project:, phase: nil, work_item: nil, trigger: :automatic)
        @project = project
        @phase = phase
        @work_item = work_item
        @trigger = trigger
      end

      def call
        self
      end

      # Returns the effective policy decision for the given phase.
      # Callers should not infer decisions from labels, queue state, or local UI state;
      # they must use this projection exclusively.
      def phase_authorized?(phase)
        policy = Automation::EffectivePolicy.call(
          project: project,
          phase: phase,
          work_item: work_item,
          trigger: trigger
        )
        policy.permitted?
      end

      # Returns all currently authorized phases.
      def authorized_phases
        Automation::Phases::ALL.select { |phase| phase_authorized?(phase) }
      end

      # Returns the effective policy decision object.
      def effective_policy(phase)
        Automation::EffectivePolicy.call(
          project: project,
          phase: phase,
          work_item: work_item,
          trigger: trigger
        )
      end

      # Convenience methods for common phases.
      def discovery_authorized?
        phase_authorized?(Automation::Phases::DISCOVERY)
      end

      def issue_preparation_authorized?
        phase_authorized?(Automation::Phases::ISSUE_PREPARATION)
      end

      def coding_authorized?
        phase_authorized?(Automation::Phases::CODING)
      end

      def merge_authorized?
        phase_authorized?(Automation::Phases::MERGE)
      end

      def release_deployment_authorized?
        phase_authorized?(Automation::Phases::RELEASE_DEPLOYMENT)
      end

      def operations_authorized?
        phase_authorized?(Automation::Phases::OPERATIONS)
      end

      # Serializable state for use across surfaces
      def to_h
        {
          project_id: project.id,
          authorized_phases: authorized_phases,
          phase_decisions: Automation::Phases::ALL.index_with { |phase| effective_policy(phase).to_h }
        }
      end

      private

      attr_reader :project, :phase, :work_item, :trigger
    end
  end
end
