# frozen_string_literal: true

module Knowledge
  module Collectors
    # Indexes decision records as knowledge artifacts and chunks
    # for unified search alongside other knowledge types.
    class DecisionRecordCollector < BaseCollector
      def collector_type
        "decision_record"
      end

      def tool_version
        "1.0.0"
      end

      def collect
        records = DecisionRecord.where(project: project).where(status: %w[active draft])
        records.map { |record| build_artifact(record) }
      end

      private

      def build_artifact(record)
        content = build_content(record)

        {
          artifact_type: "decision_record",
          scope_path: "decisions/#{record.id}",
          identifier: record.title,
          content: content,
          metadata: {
            decision_record_id: record.id,
            status: record.status,
            tags: record.tags,
            agent_run_id: record.agent_run_id,
            issue_id: record.issue_id,
            commit_sha_start: record.commit_sha_start,
            commit_sha_end: record.commit_sha_end
          },
          chunks: build_chunks(record)
        }
      end

      def build_content(record)
        parts = []
        parts << "# #{record.title}"
        parts << "\n## Summary\n#{record.summary}"
        parts << "\n## Context\n#{record.context}" if record.context.present?
        parts << "\n## Decision\n#{record.decision}"
        parts << "\n## Consequences\n#{record.consequences}" if record.consequences.present?
        parts << "\nTags: #{record.tags.join(', ')}" if record.tags.any?
        parts.join("\n")
      end

      def build_chunks(record)
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
    end
  end
end
