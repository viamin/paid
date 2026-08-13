# frozen_string_literal: true

module Knowledge
  module Collectors
    # Indexes both implementation decisions and human directional intent
    # as knowledge artifacts for unified search and prompt context.
    class DecisionCollector < BaseCollector
      def collector_type
        "decision_record"
      end

      def tool_version
        "1.1.0"
      end

      def collect
        decision_record_artifacts + change_intent_artifacts
      end

      private

      def decision_record_artifacts
        DecisionRecord.where(project: project).where(status: %w[active draft]).map do |record|
          {
            artifact_type: "decision_record",
            scope_path: "decisions/#{record.id}",
            identifier: record.title,
            content: build_decision_record_content(record),
            metadata: {
              decision_record_id: record.id,
              status: record.status,
              tags: record.tags,
              agent_run_id: record.agent_run_id,
              issue_id: record.issue_id,
              commit_sha_start: record.commit_sha_start,
              commit_sha_end: record.commit_sha_end
            },
            chunks: build_decision_record_chunks(record)
          }
        end
      end

      def change_intent_artifacts
        ChangeIntent.where(project: project).where(status: %w[active draft]).map do |record|
          {
            artifact_type: "change_intent",
            scope_path: "change_intents/#{record.id}",
            identifier: record.title,
            content: build_change_intent_content(record),
            metadata: {
              change_intent_id: record.id,
              status: record.status,
              chat_session_id: record.chat_session_id,
              issue_id: record.issue_id,
              superseded_by_id: record.superseded_by_id
            },
            chunks: build_change_intent_chunks(record)
          }
        end
      end

      def build_decision_record_content(record)
        parts = []
        parts << "# #{record.title}"
        parts << "\nStatus: #{record.status}"
        parts << "\n## Summary\n#{record.summary}"
        parts << "\n## Context\n#{record.context}" if record.context.present?
        parts << "\n## Decision\n#{record.decision}"
        parts << "\n## Consequences\n#{record.consequences}" if record.consequences.present?
        parts << "\nTags: #{record.tags.join(', ')}" if record.tags.any?
        parts.join("\n")
      end

      def build_decision_record_chunks(record)
        chunks = []

        chunks << {
          chunk_type: "summary",
          content: "Decision: #{record.title}\n#{record.summary}",
          scope_tags: record.tags,
          sequence: 0
        }

        if record.context.present?
          chunks << {
            chunk_type: "context",
            content: record.context,
            scope_tags: record.tags,
            sequence: 1
          }
        end

        chunks << {
          chunk_type: "evidence",
          content: record.decision,
          scope_tags: record.tags,
          sequence: 2
        }

        if record.consequences.present?
          chunks << {
            chunk_type: "evidence",
            content: record.consequences,
            scope_tags: record.tags,
            sequence: 3
          }
        end

        chunks
      end

      def build_change_intent_content(record)
        parts = []
        parts << "# #{record.title}"
        parts << "\nStatus: #{record.status}"
        parts << "\n## Intent\n#{record.intent}"
        parts << "\n## Behavior\n#{record.behavior}" if record.behavior.present?
        parts << "\n## Constraints\n#{record.constraints}" if record.constraints.present?
        parts << "\n## Decisions Made\n#{record.decisions_made}" if record.decisions_made.present?
        parts.join("\n")
      end

      def build_change_intent_chunks(record)
        chunks = [
          {
            chunk_type: "summary",
            content: "Change intent: #{record.title}\n#{record.intent}",
            scope_tags: [],
            sequence: 0
          }
        ]

        if record.behavior.present?
          chunks << {
            chunk_type: "context",
            content: record.behavior,
            scope_tags: [],
            sequence: 1
          }
        end

        if record.constraints.present?
          chunks << {
            chunk_type: "context",
            content: record.constraints,
            scope_tags: [],
            sequence: 2
          }
        end

        if record.decisions_made.present?
          chunks << {
            chunk_type: "evidence",
            content: record.decisions_made,
            scope_tags: [],
            sequence: 3
          }
        end

        chunks
      end
    end
  end
end
