# frozen_string_literal: true

module Knowledge
  class ArtifactStore
    attr_reader :project, :collector_run

    def initialize(project:, collector_run:)
      @project = project
      @collector_run = collector_run
    end

    def self.call(project:, collector_run:, artifact_data_list: [])
      new(project: project, collector_run: collector_run).store_all(artifact_data_list)
    end

    # Accepts an array of artifact hashes and upserts them idempotently.
    # Returns the count of artifacts stored.
    def store_all(artifact_data_list = [])
      count = 0

      artifact_data_list.each do |data|
        store_artifact(data)
        count += 1
      end

      count
    end

    private

    def store_artifact(data)
      content_hash = compute_hash(data[:content])

      existing = find_existing_artifact(data, content_hash)

      if existing
        reassign_to_current_run(existing)
      else
        # Atomic stale-then-insert to prevent interleaving with concurrent
        # collectors that could violate the partial unique index on active artifacts.
        # Under high concurrency, two transactions can both mark prior rows stale
        # and then race to insert an active row, causing a unique constraint
        # violation. In that case, we refetch the now-existing artifact and
        # reassign it to this collector_run.
        begin
          KnowledgeArtifact.transaction do
            mark_prior_stale(data)
            create_artifact(data, content_hash)
          end
        rescue ActiveRecord::RecordNotUnique
          existing_after_conflict = find_existing_artifact(data, content_hash)

          if existing_after_conflict
            reassign_to_current_run(existing_after_conflict)
          else
            raise
          end
        end
      end
    end

    def find_existing_artifact(data, content_hash)
      KnowledgeArtifact
        .where(
          project: project,
          collector_type: collector_run.collector_type,
          artifact_type: data[:artifact_type],
          scope_path: data[:scope_path],
          identifier: data[:identifier],
          content_hash: content_hash,
          status: "active"
        )
        .first
    end

    def reassign_to_current_run(artifact)
      artifact.update!(collector_run: collector_run)
    rescue ActiveRecord::RecordNotUnique
      # Another artifact in this collector_run already has the same content_hash.
      # Refetch the existing artifact instead.
      KnowledgeArtifact.find_by(
        project: project,
        collector_run: collector_run,
        content_hash: artifact.content_hash,
        status: "active"
      ) || raise
    end

    def mark_prior_stale(data)
      prior_artifacts = KnowledgeArtifact
        .where(
          project: project,
          collector_type: collector_run.collector_type,
          artifact_type: data[:artifact_type],
          scope_path: data[:scope_path],
          identifier: data[:identifier],
          status: "active"
        )

      KnowledgeChunk
        .where(knowledge_artifact_id: prior_artifacts.select(:id), status: "active")
        .update_all(status: "stale", updated_at: Time.current)

      staled_ids = prior_artifacts.pluck(:id)
      return if staled_ids.empty?

      KnowledgeArtifact.where(id: staled_ids).update_all(status: "stale", updated_at: Time.current)

      audit_events = staled_ids.map do |artifact_id|
        {
          project: project,
          event: :artifact_staled,
          actor: { type: "collector", id: collector_run.id },
          target: { type: "KnowledgeArtifact", id: artifact_id },
          details: { identifier: data[:identifier] }
        }
      end
      Knowledge::Provenance::AuditLog.record_batch(audit_events)
    end

    def create_artifact(data, content_hash)
      artifact = KnowledgeArtifact.create!(
        collector_run: collector_run,
        project: project,
        collector_type: collector_run.collector_type,
        artifact_type: data[:artifact_type],
        scope_path: data[:scope_path],
        identifier: data[:identifier],
        content: data[:content],
        content_hash: content_hash,
        metadata: data[:metadata] || {},
        status: "active"
      )

      create_chunks(artifact, data[:chunks] || [])

      Knowledge::Provenance::AuditLog.record(
        event: :artifact_created,
        project: project,
        actor: { type: "collector", id: collector_run.id },
        target: { type: "KnowledgeArtifact", id: artifact.id },
        details: { artifact_type: data[:artifact_type], identifier: data[:identifier] }
      )

      artifact
    end

    def create_chunks(artifact, chunks_data)
      chunks_data.each_with_index do |chunk, index|
        KnowledgeChunk.create!(
          knowledge_artifact: artifact,
          project: project,
          chunk_type: chunk[:chunk_type],
          content: chunk[:content],
          content_hash: compute_hash(chunk[:content]),
          scope_tags: chunk[:scope_tags] || [],
          sequence: chunk[:sequence] || index,
          status: "active"
        )
      end
    end

    def compute_hash(content)
      Digest::SHA256.hexdigest(content.to_s)
    end
  end
end
