# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010, LAYERED-VERIFY-013
      def self.call(...) = new(...).call
      def initialize(user:, project:, obligation_ids:, target_revision:, budget:, sources: [], requested_checks: [])
        @user, @project, @obligation_ids, @target_revision, @budget, @sources, @requested_checks = user, project, obligation_ids, target_revision, budget, sources, requested_checks
      end
      def call
        AuditAccess.authorize!(user:, project:)
        obligations = project.layered_verification_obligations.where(id: obligation_ids).includes(:correspondence_claims)
        raise ArgumentError, "at least one project obligation is required" if obligations.empty?
        raise ArgumentError, "target_revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.to_i.positive?
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        run = AgentRun.create!(project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit", status: "queued", trigger_type: "manual", review_depth_snapshot: project.effective_review_depth, external_metadata: metadata_for(obligations))
        ProcessRunQueueJob.perform_later
        run
      end
      private
      attr_reader :user, :project, :obligation_ids, :target_revision, :budget, :sources, :requested_checks
      def metadata_for(obligations)
        { "layered_verification" => { "obligation_ids" => obligations.ids, "sources" => sources, "target_revision" => target_revision, "budget" => budget.to_i, "plan" => Plans::Build.call(obligations:, requested_checks:), "progress" => "queued" } }
      end
    end
  end
end
