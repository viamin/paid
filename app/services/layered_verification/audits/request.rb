# frozen_string_literal: true

module LayeredVerification
  module Audits
    # The sole creation boundary for issue-less manual audit runs.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    class Request
      EmptyScopeError = Class.new(ArgumentError)
      ActiveAuditError = Class.new(ArgumentError)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, obligation_ids:, budget:, checks: [], exclusions: [], target_revision: nil)
        @project = project
        @user = user
        @obligation_ids = Array(obligation_ids).map(&:to_i).select(&:positive?).uniq
        @budget = budget
        @checks = checks
        @exclusions = exclusions
        @target_revision = target_revision
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise EmptyScopeError, "Select at least one obligation for the audit." if obligation_ids.empty?

        project.with_lock do
          raise ActiveAuditError, "An audit for this scope is already queued or in progress." if active_audit?

          create_run!
        end.tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :project, :user, :obligation_ids, :budget, :checks, :exclusions, :target_revision

      def create_run!
        obligations = project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
        raise EmptyScopeError, "Selected audit obligations are no longer available." unless obligations.size == obligation_ids.size

        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        plan = Plans::Build.call(checks:, exclusions:, revision: target_revision || obligations.filter_map(&:external_revision).uniq.join(","))
        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, trigger_type: "manual", status: "queued",
          external_metadata: audit_metadata(obligations:, plan:)
        )
      end

      def audit_metadata(obligations:, plan:)
        {
          "layered_verification_audit" => {
            "obligation_ids" => obligations.map(&:id),
            "scope" => obligations.map { |obligation| { "identity" => obligation.external_identity, "description" => obligation.scope_description } },
            "target_revision" => target_revision,
            "budget" => budget,
            "plan" => { "checks" => plan.checks, "exclusions" => plan.exclusions, "residual_gaps" => plan.residual_gaps, "revision" => plan.revision }
          }
        }
      end

      def active_audit?
        project.agent_runs.where(goal: "layered_verification_audit", status: AgentRun::UNFINISHED_STATUSES)
          .where("external_metadata -> 'layered_verification_audit' -> 'obligation_ids' @> ?::jsonb", obligation_ids.to_json)
          .exists?
      end
    end
  end
end
