# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014 @spec LAYERED-VERIFY-027
    class Request
      class EmptyScopeError < StandardError; end
      class InvalidBudgetError < StandardError; end
      class InvalidTargetRevisionError < StandardError; end
      class DuplicateAuditError < StandardError; end

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

      # Whether an already-active run overlaps the project/goal/scope/revision
      # identity. Admission callers must serialize on the project row
      # around this check; the check alone cannot close the create window.
      def self.active_run_for_identity?(project:, goal:, obligation_ids:, target_revision:)
        scope = project.agent_runs.where(goal:, base_commit_sha: target_revision, status: %w[queued running])
        wanted_ids = obligation_ids.map(&:to_i).to_set
        scope.find_each.any? do |run|
          active_ids = Array(run.external_metadata.dig("layered_verification", "obligation_ids")).map(&:to_i).to_set
          active_ids.intersect?(wanted_ids)
        end
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
        run = nil
        AgentRun.transaction do
          # Serialize admission on the project row so two concurrent approvals
          # cannot both observe no active audit and both create one; the
          # resumption path takes the same lock before re-admitting a successor.
          project.lock!
          raise DuplicateAuditError, "an audit for this scope and revision is already active" if duplicate_audit?

          lock_obligations!
          run = AgentRun.create!(run_attributes)
        end
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget, :obligation_ids, :project, :selections, :target_revision, :user

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
      end

      def lock_obligations!
        @obligations = project.layered_verification_obligations.where(id: obligation_ids).lock.order(:id).to_a
        raise EmptyScopeError, "select at least one obligation" if @obligations.empty?
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
              "input_revisions" => obligation_input_revisions,
              "budget" => budget, "plan" => Plans::Build.call(obligations:, selections:),
              "dependencies" => dependency_snapshot,
              "replay" => { "requested_at" => Time.current.iso8601, "requester_id" => user.id,
                "selected_obligation_ids" => obligations.map(&:id), "target_revision" => target_revision },
              "impact" => impact_snapshot
            }
          }
        }
      end

      def dependency_snapshot
        @dependency_snapshot ||= DependencySnapshot.call(project:)
      end

      def obligation_input_revisions
        obligations.to_h { |obligation| [ obligation.id.to_s, obligation.external_revision ] }
      end

      def impact_snapshot
        impact = Invalidation.call(obligations:, target_revision:, dependencies: dependency_snapshot)
        { "reused_check_result_ids" => impact.reusable_result_ids,
          "invalidated_check_result_ids" => impact.invalidated_result_ids,
          "limitations" => impact.limitations }
      end

      def duplicate_audit?
        self.class.active_run_for_identity?(project:, goal: "layered_verification_audit",
          obligation_ids: obligations.map(&:id), target_revision:)
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
