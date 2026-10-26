# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010
      # @spec LAYERED-VERIFY-013
      # @spec LAYERED-VERIFY-021
      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, obligation_ids: nil, source_references:, target_revision:, budget:, plan:)
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @source_references = Array(source_references).filter_map { |reference| reference.to_s.strip.presence }
        @target_revision = target_revision.to_s.strip
        @budget = budget.to_h.deep_stringify_keys
        @plan = plan.to_h.deep_stringify_keys
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate_request!

        AgentRun.create!(run_attributes).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :budget, :obligation_ids, :plan, :project, :source_references, :target_revision, :user

      def validate_request!
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "at least one source reference is required" if source_references.empty?
        raise ArgumentError, "budget must include max_tokens" unless budget["max_tokens"].to_i.positive?
        raise ArgumentError, "at least one obligation is required" if obligations.empty?
      end

      def obligations
        @obligations ||= begin
          scope = project.layered_verification_obligations.where(superseded_by_id: nil)
          scope = scope.where(id: obligation_ids) if obligation_ids.present?
          scope.order(:id).to_a
        end
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          status: "queued", trigger_type: "manual", review_depth_snapshot: project.effective_review_depth,
          external_metadata: {
            "obligation_ids" => obligations.map(&:id), "source_references" => source_references,
            "target_revision" => target_revision, "budget" => budget, "verification_plan" => plan,
            "waiting_reasons" => [], "initiated_by" => user.id
          }
        }
      end
    end
  end
end
