# frozen_string_literal: true

module LayeredVerification
  module Audits
    # The sole issue-less audit admission path. It snapshots the resolved scope
    # before queueing and intentionally has no repair side effect.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
    class Request
      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids:, budget_tokens:, available_artifacts: {})
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @budget_tokens = budget_tokens
        @available_artifacts = available_artifacts
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise ArgumentError, "budget_tokens must be positive" unless budget_tokens.to_i.positive?

        run = AgentRun.create!(run_attributes)
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :available_artifacts, :budget_tokens, :obligation_ids, :project, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).includes(:correspondence_claims).to_a.tap do |records|
          raise ActiveRecord::RecordNotFound, "one or more obligations are outside this project" unless records.size == obligation_ids.uniq.size
        end
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          external_metadata: metadata
        }
      end

      def metadata
        plan = Plans::Build.call(obligations:, available_artifacts:)
        {
          "obligation_ids" => obligations.map(&:id), "budget_tokens" => budget_tokens.to_i,
          "target_revisions" => obligations.index_by(&:id).transform_values(&:external_revision),
          "verification_plan" => plan.to_h, "initiated_via" => "manual_audit"
        }
      end
    end
  end
end
