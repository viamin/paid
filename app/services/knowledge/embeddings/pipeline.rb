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
        @generator = generator
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
          process_batch_grouped(batch).each do |result|
            total_embedded += result[:embedded]
            total_tokens += result[:tokens]
          end
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
      ensure
        close_managed_generators
      end

      private

      def eligible_chunks(project)
        scope = KnowledgeChunk.needs_embedding.includes(:project)
        scope = scope.for_project(project) if project
        scope
      end

      def process_batch_grouped(chunks)
        return [ process_batch(chunks, generator) ] if generator

        chunks.group_by(&:project).each_with_object([]) do |(project, project_chunks), results|
          configs = Knowledge::ProviderConfiguration.for_embedding_candidates(project: project)
          next if configs.empty?

          results << process_batch(project_chunks, generator_for(project, configs))
        end
      end

      def process_batch(chunks, batch_generator)
        embeddable, redaction_audit = redact_chunks(chunks)

        Knowledge::Provenance::AuditLog.record_batch(redaction_audit) if redaction_audit.any?

        return { embedded: 0, tokens: 0 } if embeddable.empty?

        texts = embeddable.map(&:content)
        results = batch_generator.call(texts: texts)

        if results.size != embeddable.size
          raise EmbeddingError,
            "Embedding count mismatch: expected #{embeddable.size}, got #{results.size}"
        end

        tokens = 0
        audit_events = []

        embeddable.zip(results).each do |chunk, result|
          Knowledge::Qdrant::PointSync.upsert_chunk!(chunk, vector: result.vector)
          attrs = { embedding_model: batch_generator.model }
          attrs[:redaction_scanned_at] = chunk.redaction_scanned_at if chunk.redaction_scanned_at_changed?
          chunk.update!(attrs)
          tokens += result.token_count

          audit_events << {
            event: :chunk_embedded,
            project: chunk.project,
            actor: { type: "embedding_pipeline" },
            target: { type: "KnowledgeChunk", id: chunk.id },
            details: { model: batch_generator.model }
          }
        end

        Knowledge::Provenance::AuditLog.record_batch(audit_events)

        { embedded: embeddable.size, tokens: tokens }
      end

      def redact_chunks(chunks)
        embeddable = []
        audit_events = []
        now = Time.current

        chunks.each do |chunk|
          result = Knowledge::Redaction::Redactor.call(text: chunk.content)

          if result.fully_redacted?
            chunk.update!(
              status: "redacted",
              content: result.clean_text,
              content_hash: Digest::SHA256.hexdigest(result.clean_text),
              redaction_scanned_at: now
            )
            log_redaction(chunk, result)
            audit_events << redaction_audit_event(chunk, result, fully_redacted: true)
          elsif result.redacted?
            chunk.update!(
              content: result.clean_text,
              content_hash: Digest::SHA256.hexdigest(result.clean_text),
              redaction_scanned_at: now
            )
            log_redaction(chunk, result)
            audit_events << redaction_audit_event(chunk, result, fully_redacted: false)
            embeddable << chunk
          else
            # Capture scan timestamp in-memory for clean chunks; persisted
            # alongside embedding_model after embedding succeeds to avoid
            # a redundant DB round-trip per chunk.
            chunk.redaction_scanned_at = now
            embeddable << chunk
          end
        end

        [ embeddable, audit_events ]
      end

      def log_redaction(chunk, result)
        Rails.logger.info(
          message: "knowledge.redaction",
          project_id: chunk.project_id,
          chunk_id: chunk.id,
          patterns_found: result.redactions.map(&:pattern).uniq,
          redaction_count: result.redactions.size,
          fully_redacted: result.fully_redacted?
        )
      end

      def redaction_audit_event(chunk, result, fully_redacted:)
        {
          event: :chunk_redacted,
          project: chunk.project,
          actor: { type: "redaction_pipeline" },
          target: { type: "KnowledgeChunk", id: chunk.id },
          details: {
            patterns_found: result.redactions.map(&:pattern).uniq.map(&:to_s),
            redaction_count: result.redactions.size,
            fully_redacted: fully_redacted
          }
        }
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

      def generator_for(project, provider_configs)
        managed_generators[project.id] ||= ProxyGenerator.new(
          project: project,
          provider_configs: provider_configs,
          containerize: true
        )
      end

      def managed_generators
        @managed_generators ||= {}
      end

      def close_managed_generators
        managed_generators.each_value(&:close)
      end
    end
  end
end
