# frozen_string_literal: true

module Knowledge
  module Embeddings
    class Pipeline
      DEFAULT_BATCH_SIZE = 100

      attr_reader :batch_size, :generator

      def initialize(batch_size: nil, generator: nil)
        raw = batch_size || ENV.fetch("EMBEDDING_BATCH_SIZE", DEFAULT_BATCH_SIZE)
        @batch_size = raw.to_i
        if @batch_size <= 0
          raise ArgumentError,
            "batch_size must be a positive integer; got #{raw.inspect}. Check EMBEDDING_BATCH_SIZE env var."
        end
        @generator = generator || Generate.new
      end

      def self.call(project: nil, batch_size: nil, generator: nil)
        new(batch_size: batch_size, generator: generator).call(project: project)
      end

      def call(project: nil)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        total_embedded = 0
        total_tokens = 0

        chunks_scope = eligible_chunks(project)

        chunks_scope.find_in_batches(batch_size: batch_size) do |batch|
          result = process_batch(batch)
          total_embedded += result[:embedded]
          total_tokens += result[:tokens]
        end

        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
        cost = Generate.estimate_cost(total_tokens)

        log_completion(total_embedded, total_tokens, cost, duration)

        {
          chunks_embedded: total_embedded,
          total_tokens: total_tokens,
          estimated_cost: cost,
          duration_seconds: duration.round(2)
        }
      end

      private

      def eligible_chunks(project)
        scope = KnowledgeChunk.needs_embedding
        scope = scope.for_project(project) if project
        scope
      end

      def process_batch(chunks)
        texts = chunks.map(&:content)
        redacted = redaction_check(texts)

        results = generator.call(texts: redacted)

        if results.size != chunks.size
          raise EmbeddingError,
            "Embedding count mismatch: expected #{chunks.size}, got #{results.size}"
        end

        tokens = 0
        audit_events = []

        chunks.zip(results).each do |chunk, result|
          Knowledge::Qdrant::PointSync.upsert_chunk!(chunk, vector: result.vector)
          chunk.update!(embedding_model: generator.model)
          tokens += result.token_count

          audit_events << {
            event: :chunk_embedded,
            project: chunk.project,
            actor: { type: "embedding_pipeline" },
            target: { type: "KnowledgeChunk", id: chunk.id },
            details: { model: generator.model }
          }
        end

        Knowledge::Provenance::AuditLog.record_batch(audit_events)

        { embedded: chunks.size, tokens: tokens }
      end

      # Placeholder for redaction — passes through until redaction issue is done.
      # Future: filter/redact sensitive content before embedding.
      def redaction_check(texts)
        texts
      end

      def log_completion(total_embedded, total_tokens, cost, duration)
        Rails.logger.info(
          message: "knowledge.embeddings.pipeline_completed",
          chunks_embedded: total_embedded,
          total_tokens: total_tokens,
          estimated_cost_usd: cost,
          duration_ms: (duration * 1000).round
        )
      end
    end
  end
end
