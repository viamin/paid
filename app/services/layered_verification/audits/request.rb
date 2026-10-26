# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      def self.call(...) = new(...).call
      def self.preview(project:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
        new(user: nil, project:, obligation_ids:, source_references:, target_revision:, budget_tokens:).preview
      end

      def initialize(user:, project:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
        @user, @project, @obligation_ids, @source_references = user, project, Array(obligation_ids), Array(source_references)
        @target_revision, @budget_tokens = target_revision, budget_tokens
      end

      def call
        AuditAccess.authorize!(user:, project:)
        preview
        create_run
      end

      def preview
        validate!
        {
          "project_id" => project.id, "obligation_ids" => obligations.map(&:id),
          "source_references" => source_references.reject(&:blank?), "target_revision" => target_revision,
          "budget_tokens" => budget_tokens.to_i,
          "dispatch_note" => "Approval queues an investigation-only audit; it cannot repair repository artifacts."
        }
      end

      private

      attr_reader :user, :project, :obligation_ids, :source_references, :target_revision, :budget_tokens

      def validate!
        raise ArgumentError, "Select at least one obligation" if obligations.empty?
        raise ArgumentError, "Provide at least one source reference" if source_references.reject(&:blank?).empty?
        raise ArgumentError, "Provide the target revision" if target_revision.blank?
        raise ArgumentError, "Budget must be a positive integer" unless budget_tokens.to_i.positive?
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).to_a.tap do |records|
          raise ActiveRecord::RecordNotFound, "One or more obligations are outside this project" unless records.size == obligation_ids.uniq.size
        end
      end

      def create_run
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          custom_prompt: "Bounded layered-verification audit. Investigation only; do not modify repository artifacts.",
          external_metadata: {
            "obligation_ids" => obligations.map(&:id), "source_references" => source_references.reject(&:blank?),
            "target_revision" => target_revision, "budget_tokens" => budget_tokens.to_i, "initiated_by_user_id" => user.id
          }
        ).tap { ProcessRunQueueJob.perform_later }
      end
    end
  end
end
