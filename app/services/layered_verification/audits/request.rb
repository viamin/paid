# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
      def self.call(...) = new(...).call

      def initialize(project:, actor:, obligation_ids:, target_revision:, budget:)
        @project, @actor, @obligation_ids, @target_revision, @budget = project, actor, obligation_ids, target_revision, budget
      end

      def call
        AuditAccess.authorize!(user: actor, project: project)
        raise ArgumentError, "Select at least one obligation" if obligations.empty?
        raise ArgumentError, "Target revision is required" if target_revision.blank?
        raise ArgumentError, "Budget must be positive" unless budget.to_i.positive?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        raise ArgumentError, "No runnable runner is available for this audit" unless runner_id && agent_type

        AgentRun.create!(project:, initiating_user: actor, runner_id:, agent_type:, goal: "layered_verification_audit",
          trigger_type: "manual", base_commit_sha: target_revision, custom_prompt: prompt, external_metadata: metadata)
      end

      private

      attr_reader :actor, :budget, :obligation_ids, :project, :target_revision

      def obligations = @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).to_a
      def metadata
        { "obligation_ids" => obligations.map(&:id), "target_revision" => target_revision, "budget" => budget.to_i,
          "initiated_by_id" => actor.id, "audit_state" => "queued", "waiting_reason" => nil }
      end

      def prompt
        "Run the bounded layered-verification audit for the recorded obligation IDs. " \
          "Do not modify repository files or start repair work."
      end
    end
  end
end
