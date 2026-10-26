# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates an investigation-only run.  The plan and resolved inputs are
    # snapshotted before queueing so later project changes cannot alter it.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      def self.call(...) = new(...).call

      def initialize(project:, user:, scope:, sources:, target_revision:, budget:, trigger: "manual")
        @project, @user, @scope, @sources, @target_revision, @budget, @trigger = project, user, scope, sources, target_revision, budget, trigger
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise ArgumentError, "an audit requires at least one resolved obligation" if scope.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.to_i.positive?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, trigger_type: trigger,
          external_metadata: { "layered_verification" => { "scope" => scope, "sources" => sources,
            "target_revision" => target_revision, "budget" => budget, "progress" => "queued", "waiting_reason" => nil } })
      end

      private

      attr_reader :project, :user, :scope, :sources, :target_revision, :budget, :trigger
    end
  end
end
