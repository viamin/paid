# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      Result = Data.define(:run, :resolved_scope, :target_revision, :budget)

      def self.call(...) = new(...).call

      def initialize(user:, project:, obligation_ids:, source_references:, target_revision:, budget:, trigger: "manual")
        @user = user
        @project = project
        @obligation_ids = obligation_ids
        @source_references = source_references
        @target_revision = target_revision
        @budget = budget
        @trigger = trigger
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise ArgumentError, "an audit needs at least one obligation" if obligations.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.to_i.positive?

        Result.new(run: create_run!, resolved_scope: obligations.map(&:external_identity), target_revision:, budget: budget.to_i)
      end

      private

      attr_reader :budget, :obligation_ids, :project, :source_references, :target_revision, :trigger, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: Array(obligation_ids)).order(:id).to_a
      end

      def create_run!
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: trigger,
          external_metadata: {
            "layered_verification" => {
              "obligation_ids" => obligations.map(&:id), "resolved_scope" => obligations.map(&:external_identity),
              "source_references" => Array(source_references), "target_revision" => target_revision,
              "budget" => budget.to_i, "initiating_user_id" => user.id, "trigger" => trigger,
              "progress" => "queued", "waiting_reason" => nil
            }
          }
        ).tap { ProcessRunQueueJob.perform_later }
      end
    end
  end
end
