# frozen_string_literal: true

module Knowledge
  module Collectors
    class ChangeIntentCollector < BaseCollector
      def collector_type
        "change_intent"
      end

      def tool_version
        "1.0.0"
      end

      def collect
        ChangeIntent.active.for_project(project).map { |record| artifact_for(record) }
      end

      def artifact_for(record)
        {
          artifact_type: "change_intent",
          scope_path: "change_intents/#{record.id}",
          identifier: record.title,
          content: build_content(record),
          metadata: {
            change_intent_id: record.id,
            status: record.status,
            chat_session_id: record.chat_session_id,
            issue_id: record.issue_id
          },
          chunks: build_chunks(record)
        }
      end

      private

      def build_content(record)
        parts = []
        parts << "# #{record.title}"
        parts << "\nStatus: #{record.status}"
        parts << "\n## Intent\n#{record.intent}"
        parts << "\n## Behavior\n#{record.behavior}" if record.behavior.present?
        parts << "\n## Constraints\n#{record.constraints}" if record.constraints.present?
        parts << "\n## Decisions Made\n#{record.decisions_made}" if record.decisions_made.present?
        parts.join("\n")
      end

      def build_chunks(record)
        chunks = [
          {
            chunk_type: "summary",
            content: "Change intent: #{record.title}\n#{record.intent}",
            sequence: 0
          }
        ]

        if record.behavior.present?
          chunks << {
            chunk_type: "context",
            content: record.behavior,
            sequence: 1
          }
        end

        if record.constraints.present?
          chunks << {
            chunk_type: "context",
            content: record.constraints,
            sequence: 2
          }
        end

        if record.decisions_made.present?
          chunks << {
            chunk_type: "evidence",
            content: record.decisions_made,
            sequence: 3
          }
        end

        chunks
      end
    end
  end
end
