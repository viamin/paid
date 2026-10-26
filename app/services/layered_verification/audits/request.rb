# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
      Preview = Data.define(:scope, :sources, :target_revision, :budget, :trigger)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, user:, scope:, sources:, target_revision:, budget:, trigger:)
        @project = project
        @user = user
        @scope = Array(scope).compact_blank
        @sources = Array(sources).compact_blank
        @target_revision = target_revision.to_s.presence
        @budget = budget.to_i
        @trigger = trigger.to_s
      end

      def preview
        Preview.new(scope:, sources:, target_revision:, budget:, trigger:)
      end

      def call
        LayeredVerification::AuditAccess.authorize!(user:, project:)
        validate!
        AgentRun.create!(run_attributes).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :project, :user, :scope, :sources, :target_revision, :budget, :trigger

      def validate!
        raise ArgumentError, "at least one resolved obligation scope is required" if scope.empty?
        raise ArgumentError, "at least one source reference is required" if sources.empty?
        raise ArgumentError, "a target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.positive?
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          base_commit_sha: target_revision,
          external_metadata: { "layered_verification_audit" => preview.to_h.stringify_keys }
        }
      end
    end
  end
end
