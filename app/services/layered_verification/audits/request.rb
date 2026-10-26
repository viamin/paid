# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      def self.call(...) = new(...).call

      def initialize(user:, project:, obligation_ids:, target_revision:, budget:)
        @user = user
        @project = project
        @obligation_ids = Array(obligation_ids).map(&:to_i).select(&:positive?).uniq
        @target_revision = target_revision.to_s.strip
        @budget = Integer(budget)
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise ArgumentError, "select at least one obligation" if obligations.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.positive?

        AgentRun.create!(
          project:, initiating_user: user, agent_type: "claude_code", goal: "layered_verification_audit",
          trigger_type: "manual", status: "queued", custom_prompt: prompt,
          external_metadata: { "layered_verification_audit" => resolved_scope }
        ).tap { ProcessRunQueueJob.perform_later }
      end

      def resolved_scope
        {
          "obligation_ids" => obligations.map(&:id),
          "sources" => obligations.map(&:external_identity),
          "target_revision" => target_revision,
          "budget" => budget,
          "initiating_user_id" => user.id,
          "trigger" => "manual"
        }
      end

      private

      attr_reader :budget, :obligation_ids, :project, :target_revision, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
      end

      def prompt
        "Run a bounded, report-only layered verification audit for #{resolved_scope.to_json}. Do not modify repository artifacts or start repair work."
      end
    end
  end
end
