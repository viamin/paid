# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      Result = Data.define(:agent_run, :scope, :budget)

      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids: nil)
        @project = project
        @user = user
        @obligation_ids = obligation_ids
      end

      def call
        AuditAccess.authorize!(user:, project:)
        scope = resolved_scope
        raise ArgumentError, "Select at least one layered-verification obligation" if scope.empty?

        run = AgentRun.create!(
          project:, initiating_user: user, issue: nil, goal: "layered_verification_audit",
          agent_type: resolved_agent_type, runner_id: resolved_runner_id, status: "queued", trigger_type: "manual",
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: { "layered_verification_audit" => request_metadata(scope) }
        )
        ProcessRunQueueJob.perform_later
        Result.new(agent_run: run, scope: scope, budget: project.project_level_max_tokens_per_run)
      end

      private

      attr_reader :project, :user, :obligation_ids

      def resolved_scope
        scope = project.layered_verification_obligations.order(:id)
        scope = scope.where(id: obligation_ids) if obligation_ids.present?
        scope.to_a
      end

      def request_metadata(scope)
        {
          "obligation_ids" => scope.map(&:id),
          "scope" => scope.map { |o| { "id" => o.id, "identity" => o.external_identity, "description" => o.scope_description,
                                      "revision" => o.external_revision, "approval_state" => o.approval_state } },
          "target_revision" => scope.map(&:external_revision).compact.uniq,
          "budget_tokens" => project.project_level_max_tokens_per_run,
          "initiating_user_id" => user.id,
          "trigger" => "manual"
        }
      end

      def resolved_runner_id
        @resolved_runner ||= AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        @resolved_runner.first
      end

      def resolved_agent_type
        @resolved_runner ||= AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        @resolved_runner.last
      end
    end
  end
end
