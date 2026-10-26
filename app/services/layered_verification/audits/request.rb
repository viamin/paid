# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      class EmptyScopeError < StandardError; end

      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids:, target_revision:, budget:, selections: {})
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @target_revision = target_revision
        @budget = budget
        @selections = selections
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise EmptyScopeError, "select at least one obligation" if obligations.empty?

        run = AgentRun.create!(run_attributes)
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget, :obligation_ids, :project, :selections, :target_revision, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          status: "queued", trigger_type: "manual", base_commit_sha: target_revision,
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: {
            "layered_verification" => {
              "obligation_ids" => obligations.map(&:id), "target_revision" => target_revision,
              "budget" => budget, "plan" => Plans::Build.call(obligations:, selections:)
            }
          }
        }
      end
    end
  end
end
