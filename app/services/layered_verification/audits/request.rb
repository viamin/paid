# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates an investigation-only run. Repository mutations are deliberately
    # not part of this admission path.
    class Request
      # @spec LAYERED-VERIFY-010
      # @spec LAYERED-VERIFY-013
      def self.call(...) = new(...).call

      def initialize(project:, actor:, obligation_ids:, revision:, budget_cents:)
        @project = project
        @actor = actor
        @obligation_ids = Array(obligation_ids).map(&:to_i).uniq
        @revision = revision.to_s
        @budget_cents = budget_cents.to_i
      end

      def call
        AuditAccess.authorize!(user: actor, project: project)
        raise ArgumentError, "target revision is required" if revision.blank?
        raise ArgumentError, "budget must be positive" unless budget_cents.positive?

        obligations = project.layered_verification_obligations.where(id: obligation_ids).order(:id)
        raise ArgumentError, "select at least one project obligation" if obligations.empty?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        run = AgentRun.create!(
          project:, initiating_user: actor, runner_id:, agent_type:, goal: "layered_verification_audit",
          trigger_type: "manual", status: "queued", cost_cents: budget_cents,
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: metadata_for(obligations)
        )
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :project, :actor, :obligation_ids, :revision, :budget_cents

      def metadata_for(obligations)
        {
          "layered_verification_audit" => {
            "obligation_ids" => obligations.ids,
            "scope" => obligations.map(&:scope_description),
            "target_revision" => revision,
            "budget_cents" => budget_cents,
            "initiating_user_id" => actor.id,
            "trigger" => "manual"
          }
        }
      end
    end
  end
end
