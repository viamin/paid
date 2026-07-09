# frozen_string_literal: true

module Knowledge
  module Redaction
    # Physical scrub workflow for already-indexed knowledge data.
    #
    # Re-runs the redaction pipeline against previously embedded/scanned
    # knowledge artifacts and chunks, then propagates the physical changes
    # into Qdrant so vector payloads can no longer surface scrubbed content
    # via semantic search. The pre-embedding redaction pipeline
    # (Knowledge::Embeddings::Pipeline) only scrubs content *before* it is
    # embedded. This service fills the gap for content that was indexed
    # before redaction patterns caught the sensitive material — typically
    # when patterns are added or updated after the fact.
    #
    # Operates in three stages:
    #
    # 1. Scan — re-run Knowledge::Redaction::Redactor against active chunk
    #    content to find newly matching chunks.
    # 2. PostgreSQL scrub — clear or replace the matched content with
    #    placeholders, update content_hash, and mark the chunk as
    #    `redacted` (or keep `active` for partial redactions).
    # 3. Qdrant cleanup — delete affected points (and/or rebuild the
    #    collection when broad scrubbing is requested) so vector search
    #    cannot surface the removed content.
    #
    # All non-dry-run actions emit KnowledgeAuditEvent records so operators
    # can audit what was scrubbed, when, and by whom.
    class Scrubber
      Result = Data.define(
        :scanned_chunks,
        :scrubbed_chunks,
        :skipped_chunks,
        :deleted_qdrant_points,
        :qdrant_collection_rebuilt,
        :duration_seconds
      )

      DEFAULT_BATCH_SIZE = 100
      DEFAULT_QDRANT_DELETE_BATCH_SIZE = 500
      DEFAULT_REBUILD_THRESHOLD = 500

      attr_reader :project, :batch_size, :qdrant_client,
        :qdrant_delete_batch_size, :actor, :dry_run, :scope_filter

      def self.call(...)
        new(...).call
      end

      def initialize(project:, batch_size: nil, qdrant_client: nil,
        qdrant_delete_batch_size: nil,
        actor: { type: "operator", id: "system" }, dry_run: false,
        scope_filter: nil)
        @project = project
        @batch_size = positive_int(batch_size, ENV.fetch("KNOWLEDGE_SCRUB_BATCH_SIZE", DEFAULT_BATCH_SIZE))
        @qdrant_client = qdrant_client
        @qdrant_delete_batch_size = positive_int(
          qdrant_delete_batch_size,
          ENV.fetch("KNOWLEDGE_SCRUB_QDRANT_BATCH_SIZE", DEFAULT_QDRANT_DELETE_BATCH_SIZE)
        )
        @actor = actor || { type: "system" }
        @dry_run = dry_run
        @scope_filter = scope_filter
      end

      def call
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        scanned_total = 0
        scrubbed_total = 0
        skipped_total = 0
        deleted_points_total = 0
        collection_rebuilt = false

        scope = scrub_scope
        scope.find_in_batches(batch_size: batch_size) do |batch|
          batch_result = process_batch(batch)

          scanned_total += batch_result[:scanned]
          scrubbed_total += batch_result[:scrubbed]
          skipped_total += batch_result[:skipped]
          deleted_points_total += batch_result[:deleted_points]
        end

        if should_rebuild_collection?(scrubbed_total)
          collection_rebuilt = rebuild_collection!
        end

        summary = build_summary(
          scanned_total: scanned_total,
          scrubbed_total: scrubbed_total,
          skipped_total: skipped_total,
          deleted_points_total: deleted_points_total,
          collection_rebuilt: collection_rebuilt
        )
        record_summary_event(summary)

        Rails.logger.info(
          message: "knowledge.redaction.scrub_completed",
          project_id: project.id,
          dry_run: dry_run,
          **summary
        )

        Result.new(
          scanned_chunks: scanned_total,
          scrubbed_chunks: scrubbed_total,
          skipped_chunks: skipped_total,
          deleted_qdrant_points: deleted_points_total,
          qdrant_collection_rebuilt: collection_rebuilt,
          duration_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time).round(3)
        )
      end

      private

      def scrub_scope
        scope = KnowledgeChunk.for_project(project).active
        scope = scope.where(knowledge_artifact_id: scope_filter[:knowledge_artifact_id]) if scope_filter&.key?(:knowledge_artifact_id)
        if scope_filter&.key?(:scope_path)
          scope = scope.joins(:knowledge_artifact).where(knowledge_artifacts: { scope_path: scope_filter[:scope_path] })
        end
        scope
      end

      def process_batch(chunks)
        scan_results = scan_chunks(chunks)
        return empty_batch_result if scan_results.empty?

        scrub_results = scrub_chunks(scan_results)
        deleted_points = delete_qdrant_points(scrub_results[:scrubbed_chunk_ids])

        {
          scanned: scan_results.size,
          scrubbed: scrub_results[:scrubbed_count],
          skipped: scrub_results[:skipped_count],
          deleted_points: deleted_points
        }
      end

      def empty_batch_result
        { scanned: 0, scrubbed: 0, skipped: 0, deleted_points: 0 }
      end

      def scan_chunks(chunks)
        chunks.filter_map do |chunk|
          result = Knowledge::Redaction::Redactor.call(text: chunk.content)
          next if !result.redacted? || result.clean_text == chunk.content

          [ chunk, result ]
        end
      end

      def scrub_chunks(scan_results)
        scrubbed_count = 0
        skipped_count = 0
        scrubbed_chunk_ids = []
        chunk_events = []
        now = Time.current

        scan_results.each do |chunk, result|
          if dry_run
            skipped_count += 1
            log_skipped(chunk, result)
            next
          end

          fully = result.fully_redacted?
          scrubbed_chunk_ids << chunk.id
          scrubbed_count += 1

          attrs = {
            content: result.clean_text,
            content_hash: Digest::SHA256.hexdigest(result.clean_text),
            status: fully ? "redacted" : "active",
            redaction_scanned_at: now
          }
          chunk.update!(attrs)

          chunk_events << build_chunk_event(chunk: chunk, result: result, fully_redacted: fully)
          log_scrubbed(chunk, result)
        end

        ::Knowledge::Provenance::AuditLog.record_batch(chunk_events) if chunk_events.any?

        {
          scrubbed_count: scrubbed_count,
          skipped_count: skipped_count,
          scrubbed_chunk_ids: scrubbed_chunk_ids
        }
      end

      def delete_qdrant_points(chunk_ids)
        return 0 if dry_run || chunk_ids.empty?
        return 0 if qdrant_client.nil?

        total_deleted = 0
        chunk_ids.each_slice(qdrant_delete_batch_size) do |slice|
          ::Knowledge::Qdrant::PointSync.delete_chunks!(slice, project: project, client: qdrant_client)
          total_deleted += slice.size
        end
        total_deleted
      end

      def should_rebuild_collection?(scrubbed_count)
        return false if dry_run || scrubbed_count.zero?
        return false if qdrant_client.nil?

        rebuild_threshold = positive_int(
          ENV["KNOWLEDGE_SCRUB_COLLECTION_REBUILD_THRESHOLD"],
          DEFAULT_REBUILD_THRESHOLD
        )
        scrubbed_count >= rebuild_threshold
      end

      def rebuild_collection!
        ::Knowledge::Qdrant::CollectionManager.new(project: project, client: qdrant_client).rebuild_schema!
        collection_name = ::Knowledge::Qdrant::CollectionManager.collection_name(project)
        ::Knowledge::Provenance::AuditLog.record(
          event: :qdrant_collection_scrubbed,
          project: project,
          actor: actor,
          details: {
            collection_name: collection_name,
            rebuild_reason: "bulk_scrub_threshold"
          }
        )
        true
      end

      def build_summary(scanned_total:, scrubbed_total:, skipped_total:, deleted_points_total:, collection_rebuilt:)
        {
          scope: scope_summary,
          matched_count: scanned_total,
          scrubbed_count: scrubbed_total,
          skipped_count: skipped_total,
          qdrant_points_deleted: deleted_points_total,
          qdrant_collection_rebuilt: collection_rebuilt,
          dry_run: dry_run
        }
      end

      def scope_summary
        return "project" unless scope_filter&.any?

        parts = []
        parts << "artifact_id=#{scope_filter[:knowledge_artifact_id]}" if scope_filter[:knowledge_artifact_id]
        parts << "scope_path=#{scope_filter[:scope_path]}" if scope_filter[:scope_path]
        parts.empty? ? "project" : parts.join(",")
      end

      def record_summary_event(summary)
        if dry_run
          Rails.logger.info(
            message: "knowledge.audit.dry_run_summary",
            event: "chunks_scrubbed",
            project_id: project.id,
            details: summary
          )
        else
          ::Knowledge::Provenance::AuditLog.record(
            event: :chunks_scrubbed,
            project: project,
            actor: actor,
            details: summary
          )
        end
      end

      def build_chunk_event(chunk:, result:, fully_redacted:)
        {
          event: :chunk_redacted,
          project: project,
          actor: actor,
          target: { type: "KnowledgeChunk", id: chunk.id },
          details: {
            patterns_found: result.redactions.map(&:pattern).uniq.map(&:to_s),
            redaction_count: result.redactions.size,
            fully_redacted: fully_redacted,
            scrub_kind: "retroactive"
          }
        }
      end

      def log_scrubbed(chunk, result)
        Rails.logger.info(
          message: "knowledge.redaction.scrub_chunk",
          project_id: project.id,
          chunk_id: chunk.id,
          patterns_found: result.redactions.map(&:pattern).uniq,
          redaction_count: result.redactions.size,
          fully_redacted: result.fully_redacted?
        )
      end

      def log_skipped(chunk, result)
        Rails.logger.info(
          message: "knowledge.redaction.scrub_chunk_dry_run",
          project_id: project.id,
          chunk_id: chunk.id,
          patterns_found: result.redactions.map(&:pattern).uniq,
          redaction_count: result.redactions.size,
          fully_redacted: result.fully_redacted?
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
