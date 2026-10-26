# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Admits the issue-less audit path. Scope resolution stays here so the UI,
    # chat, and MCP surfaces cannot drift in authorization or provenance.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
    class Request
      Result = Data.define(:run, :scope, :sources, :target_revision, :budget)

      def self.call(...) = new(...).call
      def self.preview(...) = new(...).preview

      def initialize(project:, actor:, obligation_ids:, sources:, target_revision:, budget:)
        @project = project
        @actor = actor
        @obligation_ids = obligation_ids
        @sources = sources
        @target_revision = target_revision
        @budget = budget
      end

      def call
        AuditAccess.authorize!(user: actor, project:)
        validate!
        run = AgentRun.create!(run_attributes)
        ProcessRunQueueJob.perform_later
        Result.new(run:, **resolved_request)
      end

      def preview
        AuditAccess.authorize!(user: actor, project:)
        validate!
        Result.new(run: nil, **resolved_request)
      end

      private

      attr_reader :actor, :budget, :obligation_ids, :project, :sources, :target_revision

      def validate!
        raise ArgumentError, "An audit requires a resolved scope, source, target revision, and budget" unless complete_request?
        raise ArgumentError, "One or more selected obligations are outside this project" unless scope.size == obligation_ids.size
      end

      def complete_request?
        scope.any? && normalized_sources.any? && target_revision.to_s.strip.present? && normalized_budget["max_tokens"].to_i.positive?
      end

      def scope
        @scope ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a
      end

      def normalized_sources
        @normalized_sources ||= Array(sources).filter_map { |source| source.to_s.strip.presence }
      end

      def normalized_budget
        @normalized_budget ||= budget.to_h.stringify_keys.slice("max_tokens", "max_cost_cents")
      end

      def resolved_request
        {
          scope: scope.map(&:external_identity),
          sources: normalized_sources,
          target_revision: target_revision.to_s.strip,
          budget: normalized_budget
        }
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:,
          initiating_user: actor,
          runner_id:,
          agent_type: agent_type || "claude_code",
          goal: "layered_verification_audit",
          custom_prompt: audit_prompt,
          review_depth_snapshot: project.effective_review_depth,
          status: "queued",
          trigger_type: "manual",
          external_metadata: audit_metadata
        }
      end

      def audit_metadata
        {
          "audit_scope" => scope.map(&:external_identity),
          "audit_sources" => normalized_sources,
          "audit_target_revision" => target_revision.to_s.strip,
          "audit_budget" => normalized_budget,
          "audit_trigger" => "manual",
          "audit_progress" => "queued",
          "audit_waiting_reason" => nil
        }
      end

      def audit_prompt
        "Conduct a bounded, report-only layered-verification audit. Do not modify repository files or start repair work. " \
          "Record evidence and limitations for the resolved scope in the audit report."
      end
    end
  end
end
