# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      def self.call(...) = new(...).call

      def initialize(project:, user:, obligations:, budget:)
        @project = project
        @user = user
        @obligations = Array(obligations)
        @budget = Integer(budget)
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise ArgumentError, "select at least one obligation" if obligations.empty?
        raise ArgumentError, "budget must be positive" unless budget.positive?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          external_metadata: metadata)
      end

      private

      attr_reader :project, :user, :obligations, :budget

      def metadata
        { "obligation_ids" => obligations.map(&:id), "budget" => budget,
          "resolved_scope" => obligations.map { |obligation| { "id" => obligation.id, "identity" => obligation.external_identity, "revision" => obligation.external_revision } } }
      end
    end
  end
end
