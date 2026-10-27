# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      class EmptyScopeError < StandardError; end
      class InvalidBudgetError < StandardError; end
      class InvalidTargetRevisionError < StandardError; end

      MIN_BUDGET_MINUTES = 1
      MAX_BUDGET_MINUTES = 120

      def self.call(...) = new(...).call

      def self.resolve_budget!(budget)
        value = budget.to_h["max_minutes"] || budget.to_h[:max_minutes]
        minutes = Integer(value, exception: false)
        unless minutes&.between?(MIN_BUDGET_MINUTES, MAX_BUDGET_MINUTES)
          raise InvalidBudgetError, "budget must be between 1 and 120 minutes"
        end

        { "max_minutes" => minutes }
      end

      def self.resolve_target_revision!(project:, target_revision:)
        revision = target_revision.to_s
        raise InvalidTargetRevisionError, "target revision is required" if revision.blank?

        project.client.commit(project.full_name, revision).sha.to_s.presence ||
          raise(InvalidTargetRevisionError, "target revision could not be resolved")
      rescue GithubClient::Error, Faraday::Error
        raise InvalidTargetRevisionError, "target revision could not be resolved"
      end

      def initialize(project:, user:, obligation_ids:, target_revision:, budget:, selections: {})
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @target_revision = target_revision
        @budget = budget
        @selections = selections
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise EmptyScopeError, "select at least one obligation" if obligations.empty?
        validate_budget!
        validate_target_revision!

        run = AgentRun.create!(run_attributes)
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget, :obligation_ids, :project, :selections, :target_revision, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          status: "queued", trigger_type: "manual", base_commit_sha: target_revision,
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: {
            "layered_verification" => {
              "obligation_ids" => obligations.map(&:id), "target_revision" => target_revision,
              "budget" => budget, "plan" => Plans::Build.call(obligations:, selections:)
            }
          }
        }
      end

      def validate_target_revision!
        @target_revision = self.class.resolve_target_revision!(project:, target_revision:)
      end

      def validate_budget!
        @budget = self.class.resolve_budget!(budget)
      end
    end
  end
end
