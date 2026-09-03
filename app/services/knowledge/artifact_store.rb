# frozen_string_literal: true

module Knowledge
  class ArtifactStore
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_002

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
      with_artifact_lock(data) do
        content_hash = compute_hash(data[:content])
        existing = find_existing_artifact(data, content_hash)

        if existing
          reassign_to_current_run(existing)
        else
          begin
            replace_artifact(data, content_hash)
          rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
            raise unless unique_conflict?(e)

            recover_conflicted_artifact(data, content_hash)
          end
        end
      end
    end

    def replace_artifact(data, content_hash)
      # Atomic stale-then-insert to prevent interleaving with concurrent
      # collectors that could violate the partial unique index on active artifacts.
      KnowledgeArtifact.transaction do
        mark_prior_stale(data)
        create_artifact(data, content_hash)
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

    # Broadened lookup using only the columns covered by the unique index
    # (collector_run_id, content_hash). This handles cross-scope hash
    # collisions where a different scope_path/identifier produced the same
    # content_hash within the same collector run.
    def find_by_run_and_hash(content_hash)
      KnowledgeArtifact.find_by(
        collector_run: collector_run,
        content_hash: content_hash,
        status: "active"
      )
    end

    def find_active_artifact(data)
      KnowledgeArtifact.find_by(
        project: project,
        collector_type: collector_run.collector_type,
        artifact_type: data[:artifact_type],
        scope_path: data[:scope_path],
        identifier: data[:identifier],
        status: "active"
      )
    end

    def recover_conflicted_artifact(data, content_hash)
      matching_artifact = find_existing_artifact(data, content_hash)
      return reassign_to_current_run(matching_artifact) if matching_artifact

      active_artifact = find_active_artifact(data)
      return replace_artifact(data, content_hash) if active_artifact

      run_hash_artifact = find_by_run_and_hash(content_hash)
      return reassign_to_current_run(run_hash_artifact) if run_hash_artifact

      raise ActiveRecord::RecordNotUnique, "Could not recover conflicting knowledge artifact insert"
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless unique_conflict?(e)

      matching_artifact = find_existing_artifact(data, content_hash)
      return reassign_to_current_run(matching_artifact) if matching_artifact

      run_hash_artifact = find_by_run_and_hash(content_hash)
      return reassign_to_current_run(run_hash_artifact) if run_hash_artifact

      raise
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

      return unless prior_artifacts.exists?

      # Stale and audit in batches to avoid materializing all IDs at once.
      # Collect IDs before update_all for audit event target_id values.
      prior_artifacts.in_batches(of: 1000) do |batch|
        ids = batch.pluck(:id)
        batch.update_all(status: "stale", updated_at: Time.current)

        audit_events = ids.map do |artifact_id|
          {
            project: project,
            event: :artifact_staled,
            actor: { type: "collector", id: collector_run.id },
            target: { type: "KnowledgeArtifact", id: artifact_id },
            details: { identifier: data[:identifier], uri: staled_artifact_uri(data) }
          }
        end
        Knowledge::Provenance::AuditLog.record_batch(audit_events)
      end
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
        details: { artifact_type: data[:artifact_type], identifier: data[:identifier], uri: artifact.knowledge_uri }
      )

      artifact
    end

    def staled_artifact_uri(data)
      Knowledge::Uri.build_artifact(
        project_id: project.id,
        artifact_type: data[:artifact_type],
        scope_path: data[:scope_path],
        identifier: data[:identifier]
      )
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

    def unique_conflict?(exception)
      case exception
      when ActiveRecord::RecordNotUnique
        true
      when ActiveRecord::RecordInvalid
        exception.record.errors[:content_hash].any?
      else
        false
      end
    end

    def compute_hash(content)
      Digest::SHA256.hexdigest(content.to_s)
    end

    def with_artifact_lock(data)
      execute_lock_sql(ADVISORY_LOCK_SQL, advisory_lock_key(data))
      yield
    ensure
      execute_lock_sql(ADVISORY_UNLOCK_SQL, advisory_lock_key(data))
    end

    def advisory_lock_key(data)
      Digest::SHA256
        .digest([
          project.id,
          collector_run.collector_type,
          data[:artifact_type],
          data[:scope_path],
          data[:identifier]
        ].join(":"))
        .unpack("l>")
        .first
    end

    def execute_lock_sql(sql, lock_key)
      ActiveRecord::Base.connection.raw_connection.exec_params(sql, [ LOCK_NAMESPACE, lock_key ])
    end
  end
end
