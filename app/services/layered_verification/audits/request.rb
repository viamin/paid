# frozen_string_literal: true

module LayeredVerification
  module Audits
    # The single admission boundary shared by project UI and chat/MCP. It only
    # queues an investigation run; no repair goal or target-repository write is
    # reachable from this service.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
    class Request
      DuplicateAuditError = Class.new(StandardError)
      NoRunnableRunnerError = Class.new(StandardError)

      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids:, source_references:, target_revision:, budget:, checks:, omissions:, residual_gaps:)
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @source_references = source_references
        @target_revision = target_revision
        @budget = budget
        @checks = checks
        @omissions = omissions
        @residual_gaps = residual_gaps
      end

      def call
        AuditAccess.authorize!(user:, project:)
        plan = Plans::Build.call(checks:, omissions:, residual_gaps:)
        project.with_lock { create_run!(plan) }.tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :budget, :checks, :obligation_ids, :omissions, :project, :residual_gaps, :source_references, :target_revision, :user

      def create_run!(plan)
        raise ArgumentError, "target revision is required" if target_revision.to_s.blank?
        raise ArgumentError, "audit scope requires at least one obligation" if obligations.empty?
        raise DuplicateAuditError, "An audit for this scope and revision is already in progress." if duplicate_run?

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        raise NoRunnableRunnerError, "No runnable runner could be resolved for this project." unless agent_type

        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, trigger_type: "manual", status: "queued",
          external_metadata: { "layered_verification_audit" => audit_metadata(plan) }
        )
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: Array(obligation_ids)).order(:id).to_a
      end

      def duplicate_run?
        project.agent_runs.where(goal: "layered_verification_audit", status: AgentRun::DEDUP_BLOCKING_STATUSES).any? do |run|
          metadata = run.external_metadata.fetch("layered_verification_audit", {})
          metadata["target_revision"] == target_revision && metadata["obligation_ids"] == obligations.map(&:id)
        end
      end

      def audit_metadata(plan)
        {
          "obligation_ids" => obligations.map(&:id),
          "scope" => obligations.map { |obligation| { "identity" => obligation.external_identity, "description" => obligation.scope_description, "approval_state" => obligation.approval_state } },
          "source_references" => Array(source_references).map(&:to_s),
          "target_revision" => target_revision.to_s,
          "budget" => budget.to_h,
          "plan" => { "selected_checks" => plan.selected_checks.map(&:to_h), "omissions" => plan.omissions, "residual_gaps" => plan.residual_gaps },
          "trigger" => "manual_audit",
          "initiating_user_id" => user.id
        }
      end
    end
  end
end
