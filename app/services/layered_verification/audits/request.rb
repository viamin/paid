# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates the investigation-only run shared by the project, chat, and MCP entry points.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    class Request
      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids:, budget:)
        @project = project
        @user = user
        @obligation_ids = Array(obligation_ids).map(&:to_i).uniq
        @budget = Integer(budget)
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate!
        run = create_run
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget, :obligation_ids, :project, :user

      def validate!
        raise ArgumentError, "Select at least one obligation." if obligation_ids.empty?
        raise ArgumentError, "Audit budget must be positive." unless budget.positive?
        raise ArgumentError, "Audit budget exceeds the project limit." if budget > project.account.default_max_tokens_per_run
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a.tap do |records|
          raise ActiveRecord::RecordNotFound, "One or more obligations are not in this project." unless records.size == obligation_ids.size
        end
      end

      def create_run
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:,
          initiating_user: user,
          runner_id:,
          agent_type: agent_type || "claude_code",
          goal: "layered_verification_audit",
          trigger_type: "manual",
          status: "queued",
          external_metadata: { "layered_verification_audit" => audit_metadata }
        )
      end

      def audit_metadata
        {
          "obligation_ids" => obligations.map(&:id),
          "sources" => obligations.index_by(&:id).transform_values(&:external_identity),
          "target_revision" => target_revision,
          "budget" => budget,
          "initiating_user_id" => user.id,
          "trigger" => "manual"
        }
      end

      def target_revision
        revisions = obligations.filter_map(&:external_revision).uniq
        return revisions.first if revisions.one?

        { "obligations" => obligations.index_by(&:id).transform_values(&:external_revision) }
      end
    end
  end
end
