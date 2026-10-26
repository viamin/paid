# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010
      # @spec LAYERED-VERIFY-013
      BudgetExceededError = Class.new(StandardError)
      NoRunnableRunnerError = Class.new(StandardError)

      def self.call(...) = new(...).call

      def initialize(project:, user:, scope:, sources:, target_revision:, budget:)
        @project, @user, @scope, @sources, @target_revision, @budget = project, user, scope, sources, target_revision, budget
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate_request!
        check_budget!
        run = create_run!
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :project, :user, :scope, :sources, :target_revision, :budget

      def validate_request!
        raise ArgumentError, "an audit scope is required" if scope.blank?
        raise ArgumentError, "at least one source is required" if sources.blank?
        raise ArgumentError, "a target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.to_i.positive?
      end

      def check_budget!
        return if CostBudgets::Check.call(project)[:allowed]

        raise BudgetExceededError, "Your project's AI budget has been reached."
      end

      def create_run!
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        raise NoRunnableRunnerError, "No runnable agent runner is available for this project." unless runner_id && agent_type

        AgentRun.create!(project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          trigger_type: "manual", status: "queued", custom_prompt: audit_prompt,
          external_metadata: { "layered_verification_audit" => request_metadata })
      end

      def audit_prompt
        "Bounded layered-verification audit. Investigation only; do not modify canonical intent, models, specs, tests, or code."
      end

      def request_metadata
        { "scope" => Array(scope), "sources" => Array(sources), "target_revision" => target_revision,
          "budget" => budget.to_i, "initiating_user_id" => user.id, "trigger" => "manual" }
      end
    end
  end
end
