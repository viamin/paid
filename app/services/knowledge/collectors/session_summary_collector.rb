# frozen_string_literal: true

module Knowledge
  module Collectors
    # Builds the knowledge-artifact shape for an AgentRunSessionSummary.
    # Not registered with Knowledge::CollectorRunner's periodic repo scan —
    # summaries are synced on demand via Knowledge::SessionSummaries::SyncKnowledgeArtifact,
    # the same pattern ChangeIntentCollector uses for ChangeIntent records.
    class SessionSummaryCollector < BaseCollector
      def collector_type
        "session_summary"
      end

      def tool_version
        "1.0.0"
      end

      def collect
        AgentRunSessionSummary.for_project(project).map { |record| artifact_for(record) }
      end

      def artifact_for(record)
        {
          artifact_type: "session_summary",
          scope_path: "agent_runs/#{record.agent_run_id}/session_summary",
          identifier: "Agent run ##{record.agent_run_id}",
          content: build_content(record),
          metadata: {
            agent_run_session_summary_id: record.id,
            agent_run_id: record.agent_run_id,
            change_intent_id: record.change_intent_id,
            issue_id: record.issue_id,
            pull_request_number: record.pull_request_number,
            pull_request_url: record.pull_request_url,
            status: record.status
          },
          chunks: build_chunks(record)
        }
      end

      private

      def build_content(record)
        parts = [ "# Session Summary: Agent run ##{record.agent_run_id}" ]
        parts << "\nStatus: #{record.status}"
        parts << "\n## Summary\n#{record.summary}"
        parts << section("Files Touched", record.files_touched)
        parts << section("Decisions", record.decisions)
        parts << section("Assumptions", record.assumptions)
        parts << section("Failures", record.failures)
        parts << section("Follow-ups", record.follow_ups)
        parts << section("Learnings", record.learnings)
        parts.compact.join("\n")
      end

      def section(heading, items)
        return nil if items.blank?

        "\n## #{heading}\n#{bullet_list(items)}"
      end

      def bullet_list(items)
        Array(items).map { |item| "- #{item}" }.join("\n")
      end

      def build_chunks(record)
        chunks = [
          { chunk_type: "summary", content: record.summary.to_s, sequence: 0 }
        ]

        if record.decisions.present?
          chunks << { chunk_type: "evidence", content: bullet_list(record.decisions), sequence: 1 }
        end

        if record.learnings.present?
          chunks << { chunk_type: "evidence", content: bullet_list(record.learnings), sequence: 2 }
        end

        chunks
      end
    end
  end
end
