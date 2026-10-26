# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-013
      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, obligations:, target_revision:, budget_tokens:, plan:)
        @project = project
        @user = user
        @obligations = obligations
        @target_revision = target_revision
        @budget_tokens = budget_tokens
        @plan = plan
      end

      def call
        validate!
        AgentRun.create!(run_attributes).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :budget_tokens, :obligations, :plan, :project, :target_revision, :user

      def validate!
        raise ArgumentError, "at least one obligation is required" if obligations.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget_tokens.to_i.positive?
        raise ArgumentError, "obligations must belong to the project" unless obligations.all? { |obligation| obligation.project_id == project.id }
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:,
          initiating_user: user,
          runner_id:,
          agent_type:,
          goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth,
          status: "queued",
          trigger_type: "manual",
          base_commit_sha: target_revision,
          external_metadata: { "layered_verification" => audit_metadata }
        }
      end

      def audit_metadata
        {
          "obligation_ids" => obligations.map(&:id),
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens.to_i,
          "plan" => plan
        }
      end
    end
  end
end
