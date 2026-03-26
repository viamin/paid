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
        mark_prior_stale(data)
        create_artifact(data, content_hash)
      end
    end

    def find_existing_artifact(data, content_hash)
      KnowledgeArtifact
        .joins(collector_run: :project_version)
        .where(
          project: project,
          artifact_type: data[:artifact_type],
          scope_path: data[:scope_path],
          identifier: data[:identifier],
          content_hash: content_hash,
          status: "active",
          collector_runs: { collector_type: collector_run.collector_type }
        )
        .first
    end

    def reassign_to_current_run(artifact)
      artifact.update!(collector_run: collector_run)
    end

    def mark_prior_stale(data)
      prior_artifacts = KnowledgeArtifact
        .where(
          project: project,
          artifact_type: data[:artifact_type],
          scope_path: data[:scope_path],
          identifier: data[:identifier],
          status: "active"
        )

      KnowledgeChunk
        .where(knowledge_artifact_id: prior_artifacts.select(:id), status: "active")
        .update_all(status: "stale")

      prior_artifacts.update_all(status: "stale")
    end

    def create_artifact(data, content_hash)
      KnowledgeArtifact.transaction do
        artifact = KnowledgeArtifact.create!(
          collector_run: collector_run,
          project: project,
          artifact_type: data[:artifact_type],
          scope_path: data[:scope_path],
          identifier: data[:identifier],
          content: data[:content],
          content_hash: content_hash,
          metadata: data[:metadata] || {},
          status: "active"
        )

        create_chunks(artifact, data[:chunks] || [])

        artifact
      end
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
