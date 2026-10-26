# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
      Preview = Data.define(:project, :obligations, :budget, :target_revision, :plan) do
        def to_h
          {
            "project_id" => project.id,
            "scope" => obligations.map { |obligation| { "id" => obligation.id, "source" => obligation.external_identity, "revision" => obligation.external_revision } },
            "business_intent_validation" => obligations.map { |obligation| {
              "source" => obligation.external_identity, "approval_state" => obligation.approval_state,
              "approved_revision_reference" => obligation.approved_revision_reference
            } },
            "budget" => budget,
            "target_revision" => target_revision,
            "plan" => plan.to_h
          }
        end
      end

      def self.preview(...) = new(...).preview
      def self.dispatch(...) = new(...).dispatch

      def initialize(project:, user:, obligation_ids: nil, budget: nil, target_revision: nil, formal_model: nil)
        @project = project
        @user = user
        @obligation_ids = obligation_ids
        @budget = budget
        @target_revision = target_revision
        @formal_model = formal_model
      end

      def preview
        @preview ||= Preview.new(project:, obligations:, budget: resolved_budget, target_revision: resolved_revision,
          plan: LayeredVerification::Plans::Build.call(obligations:, formal_model:))
      end

      def dispatch
        LayeredVerification::AuditAccess.authorize!(user:, project:)
        audit = preview
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        raise ArgumentError, "No runnable runner could be resolved for this project." unless runner_id && agent_type

        run = project.with_lock do
          AgentRun.create!(
            project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
            review_depth_snapshot: project.effective_review_depth, trigger_type: "manual", status: "queued",
            custom_prompt: audit_prompt(audit), external_metadata: { "layered_verification_audit" => audit.to_h }
          )
        end
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget, :formal_model, :obligation_ids, :project, :target_revision, :user

      def obligations
        scope = project.layered_verification_obligations.order(:id)
        scope = scope.where(id: Array(obligation_ids)) if obligation_ids.present?
        records = scope.to_a
        raise ArgumentError, "Select at least one resolved verification obligation." if records.empty?

        records
      end

      def resolved_budget
        requested = Integer(budget || project.account.default_max_tokens_per_run)
        raise ArgumentError, "Audit budget must be positive." unless requested.positive?

        requested
      rescue ArgumentError, TypeError
        raise ArgumentError, "Audit budget must be a positive integer."
      end

      def resolved_revision
        target_revision.presence || obligations.map(&:external_revision).compact.uniq.one?
      end

      def audit_prompt(audit)
        "Perform a report-only layered verification audit. Do not modify canonical intent, models, specs, tests, or production code. Record evidence and findings only. Audit plan: #{audit.plan.to_h.to_json}"
      end
    end
  end
end
