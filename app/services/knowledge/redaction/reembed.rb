# frozen_string_literal: true

module Knowledge
  module Redaction
    # Re-embedding workflow for chunks whose content was retroactively scrubbed.
    #
    # When a chunk is partially redacted (not fully redacted), the content
    # hash changes but the chunk remains `active`. The pre-existing
    # embedding in Qdrant is now stale and must be recomputed so semantic
    # search surfaces the redacted text, not the original sensitive
    # material. Fully redacted chunks are excluded — they should never be
    # re-embedded because they are not searchable.
    #
    # This service delegates embedding generation to the supplied
    # generator (typically `Knowledge::Embeddings::Generate` or
    # `Knowledge::Embeddings::ProxyGenerator`) and point upserts to
    # `Knowledge::Qdrant::PointSync`. It records `chunk_embedded` audit
    # events (with `reembedded: true` in details) so operators can trace
    # what was re-embedded and when.
    class Reembed
      Result = Data.define(:reembedded_count, :skipped_count, :duration_seconds)

      DEFAULT_BATCH_SIZE = 100
      DEFAULT_LOOKBACK = 24.hours

      attr_reader :project, :batch_size, :generator, :actor, :since, :chunk_ids

      def self.call(...)
        new(...).call
      end

      def initialize(project:, generator:, batch_size: nil, since: nil, chunk_ids: nil,
        actor: { type: "operator", id: "system" })
        raise ArgumentError, "generator is required" if generator.nil?
        if since.present? && chunk_ids.present?
          raise ArgumentError, "Pass either `since` or `chunk_ids`, not both"
        end

        @project = project
        @batch_size = positive_int(batch_size, ENV.fetch("KNOWLEDGE_REEMBED_BATCH_SIZE", DEFAULT_BATCH_SIZE))
        @generator = generator
        @actor = actor || { type: "system" }
        @since = since
        @chunk_ids = chunk_ids
      end

      # Re-embed all partially redacted chunks for a project. A partially
      # redacted chunk is `active`, has a prior `embedding_model`, and
      # still contains at least one character of non-redacted content.
      #
      # Operators can either pass:
      # - `chunk_ids:` — an explicit list of chunk IDs to re-embed.
      # - `since:` — a timestamp; only chunks scanned for redaction at or
      #   after this time will be re-embedded (default: 24 hours ago).
      def call
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reembedded = 0
        skipped = 0

        eligible_scope.find_in_batches(batch_size: batch_size) do |batch|
          texts = batch.map(&:content)
          results = generator.call(texts: texts)
          results = Array(results)

          if results.size != batch.size
            raise Knowledge::Embeddings::EmbeddingError,
              "Reembed batch mismatch: expected #{batch.size}, got #{results.size}"
          end

          batch.zip(results).each do |chunk, embed_result|
            if embed_result.nil? || embed_result.vector.nil?
              skipped += 1
              next
            end

            upsert_and_audit(chunk, embed_result)
            reembedded += 1
          end
        end

        log_completion(reembedded, skipped, start_time)

        Result.new(
          reembedded_count: reembedded,
          skipped_count: skipped,
          duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round(3)
        )
      end

      private

      def eligible_scope
        scope = KnowledgeChunk
          .for_project(project)
          .where(status: "active")
          .where.not(embedding_model: nil)

        if chunk_ids.present?
          scope.where(id: chunk_ids)
        else
          scope.where(redaction_scanned_at: lookback_threshold..)
        end
      end

      def lookback_threshold
        since || DEFAULT_LOOKBACK.ago
      end

      def upsert_and_audit(chunk, embed_result)
        ::Knowledge::Qdrant::PointSync.upsert_chunk!(chunk, vector: embed_result.vector)
        ::Knowledge::Provenance::AuditLog.record(
          event: :chunk_embedded,
          project: project,
          actor: actor,
          target: { type: "KnowledgeChunk", id: chunk.id },
          details: {
            model: generator.model,
            reembedded: true
          }
        )
      end

      def log_completion(reembedded, skipped, start_time)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        Rails.logger.info(
          message: "knowledge.redaction.reembed_completed",
          project_id: project.id,
          reembedded_count: reembedded,
          skipped_count: skipped,
          duration_seconds: duration.round(3)
        )
      end

      def positive_int(value, fallback)
        raw = value.nil? || (value.is_a?(String) && value.strip.empty?) ? fallback : value
        parsed = raw.to_i
        parsed <= 0 ? fallback.to_i : parsed
      end
    end
  end
end
