# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates the issue-less audit run shared by project, chat, and MCP entry
    # points. The prompt is intentionally audit-only; the execution workflow
    # additionally never publishes an audit branch.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      ScopeRequiredError = Class.new(ArgumentError)

      def self.call(...) = new(...).call

      def initialize(user:, project:, obligation_ids:, sources:, target_revision:, budget: {})
        @user = user
        @project = project
        @obligation_ids = Array(obligation_ids).map(&:to_i).select(&:positive?).uniq
        @sources = Array(sources).map(&:to_s).map(&:strip).reject(&:blank?)
        @target_revision = target_revision.to_s.strip
        @budget = budget.to_h.deep_stringify_keys
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate_scope!
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          custom_prompt: audit_prompt, external_metadata: metadata, review_depth_snapshot: project.effective_review_depth,
          status: "queued", trigger_type: "manual"
        ).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :budget, :obligation_ids, :project, :sources, :target_revision, :user

      def validate_scope!
        raise ScopeRequiredError, "select at least one obligation" if obligation_ids.empty?
        raise ScopeRequiredError, "provide at least one source reference" if sources.empty?
        raise ScopeRequiredError, "provide a target revision" if target_revision.blank?
        raise ScopeRequiredError, "selected obligations are not in this project" unless obligations.count == obligation_ids.size
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids)
      end

      def metadata
        { "layered_verification_audit" => { "obligation_ids" => obligation_ids, "sources" => sources,
          "target_revision" => target_revision, "budget" => budget, "initiating_user_id" => user.id } }
      end

      def audit_prompt
        <<~PROMPT
          Perform a bounded layered-verification audit only. Scope: obligations #{obligation_ids.join(", ")}; sources: #{sources.join(", ")}; target revision: #{target_revision}; budget: #{budget.to_json}.
          Do not modify repository files, canonical intent, models, specs, tests, production code, GitHub, or start a repair. Record source-grounded observations, limitations, omitted checks, and uncertainty for the report.
        PROMPT
      end
    end
  end
end
