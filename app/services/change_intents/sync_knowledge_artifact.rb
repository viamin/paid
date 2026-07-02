# frozen_string_literal: true

module ChangeIntents
  class SyncKnowledgeArtifact
    COLLECTOR_TYPE = "change_intent".freeze
    SYNTHETIC_BRANCH = "change-intents".freeze

    attr_reader :change_intent

    def initialize(change_intent:)
      @change_intent = change_intent
    end

    def self.call(...)
      new(...).call
    end

    def call
      collector_run.mark_running! unless collector_run.status == "running"
      collector_run.update!(tool_version: collector.tool_version)

      count = Knowledge::ArtifactStore.new(project: project, collector_run: collector_run)
        .store_all([ collector.artifact_for(change_intent) ])

      collector_run.mark_completed!(count: count)
      KnowledgeArtifact.bust_artifact_counts_cache(project.id)
      count
    rescue StandardError => error
      collector_run.mark_failed!(error: error.message)
      raise
    end

    private

    def collector
      @collector ||= Knowledge::Collectors::ChangeIntentCollector.new(
        project: project,
        project_version: project_version,
        collector_run: collector_run,
        options: {}
      )
    end

    def collector_run
      @collector_run ||= CollectorRun.create_or_find_by!(
        project_version: project_version,
        collector_type: COLLECTOR_TYPE
      )
    end

    def project_version
      @project_version ||= ProjectVersion.create_or_find_by!(
        project: project,
        commit_sha: synthetic_commit_sha
      ) do |version|
        version.branch = SYNTHETIC_BRANCH
        version.committed_at = change_intent.created_at
      end
    end

    def synthetic_commit_sha
      Digest::SHA1.hexdigest("change-intents/#{project.id}")[0, 40]
    end

    def project
      change_intent.project
    end
  end
end
