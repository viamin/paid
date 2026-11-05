# frozen_string_literal: true

module Automation
  # Rolls a project back to the fail-closed posture without erasing evidence.
  # Existing actions may finish, but their next admission boundary is held.
  # @spec BOUNDED-PHASE-AUTHORIZATION-005 @spec BOUNDED-PHASE-AUTHORIZATION-009
  class DelegationRollback
    def self.call(project:, reason:, actor: nil)
      new(project:, reason:, actor:).call
    end

    def initialize(project:, reason:, actor: nil)
      @project = project
      @reason = reason.to_s
      @actor = actor
    end

    def call
      project.with_lock do
        project.update!(delegation_posture: "conservative",
          delegation_posture_revision: project.delegation_posture_revision + 1)
      end
      held = 0
      project.agent_runs.where(admission_state: "active").find_each do |run|
        held += 1 if AdmissionLifecycle.call(agent_run: run, transition: :hold, reason:, actor:)
      end
      Audit::RecordEvent.call(action: "delegation.rolled_back", actor:, subject: project,
        metadata: { "reason" => reason, "posture" => "conservative",
                    "posture_revision" => project.delegation_posture_revision, "held_runs" => held })
      { posture: project.delegation_posture, posture_revision: project.delegation_posture_revision,
        held_runs: held }
    end

    private

    attr_reader :project, :reason, :actor
  end
end
