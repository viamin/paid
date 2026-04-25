# frozen_string_literal: true

module Notifications
  module Rules
    class ZeroIterationTimeout < Rule
      SOURCE = "zero_iteration_timeout"

      private

      def source = SOURCE

      def auto_resolve?
        false
      end

      def detect(scope)
        Array(scope).select do |agent_run|
          agent_run.status == "timeout" &&
            agent_run.iterations.to_i.zero? &&
            agent_run.tokens_input.to_i.zero?
        end
      end

      def build(agent_run)
        {
          severity: :error,
          title: "Agent run ##{agent_run.id} hit #{agent_run.duration_seconds || agent_run.duration}s wall clock with no LLM traffic",
          description: description_for(agent_run),
          nav_section: "agent_runs",
          action_url: project_agent_run_path(agent_run.project, agent_run),
          metadata: {
            duration_seconds: agent_run.duration_seconds || agent_run.duration,
            project_id: agent_run.project_id,
            source_pull_request_number: agent_run.source_pull_request_number,
            trigger_type: agent_run.trigger_type,
            providers_attempted: Array(agent_run.providers_attempted).map { |attempt| attempt["provider"] }.compact
          }.compact
        }
      end

      def description_for(agent_run)
        details = []
        details << "project #{agent_run.project.name}"
        details << "issue ##{agent_run.issue.github_number}" if agent_run.issue
        details << "PR ##{agent_run.source_pull_request_number}" if agent_run.source_pull_request_number.present?
        details << "draft follow-up" if agent_run.count_toward_draft_review_round?
        details << "no container_id" if agent_run.container_id.blank?
        details << "zero iterations"
        details << "zero input tokens"
        details.join(", ")
      end
    end
  end
end
