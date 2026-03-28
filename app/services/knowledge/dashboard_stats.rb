# frozen_string_literal: true

module Knowledge
  class DashboardStats
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        projects_indexed: projects_indexed,
        projects_total: projects_total,
        total_artifacts: total_artifacts,
        stale_artifacts: stale_artifacts,
        stale_percent: stale_percent,
        artifacts_by_type: artifacts_by_type,
        last_collection_at: last_collection_at
      }
    end

    private

    def project_ids
      @project_ids ||= Project.where(account_id: account.id).pluck(:id)
    end

    def artifacts
      @artifacts ||= KnowledgeArtifact.where(project_id: project_ids)
    end

    def projects_total
      @projects_total ||= project_ids.size
    end

    def projects_indexed
      @projects_indexed ||= KnowledgeArtifact.where(project_id: project_ids)
        .select(:project_id).distinct.count
    end

    def total_artifacts
      @total_artifacts ||= artifacts.active.count
    end

    def stale_artifacts
      @stale_artifacts ||= artifacts.stale.count
    end

    def stale_percent
      total = total_artifacts + stale_artifacts
      return 0 if total.zero?

      ((stale_artifacts.to_f / total) * 100).round
    end

    def artifacts_by_type
      @artifacts_by_type ||= artifacts.active.group(:artifact_type).count
        .sort_by { |_, v| -v }
    end

    def last_collection_at
      @last_collection_at ||= CollectorRun
        .joins(project_version: :project)
        .where(projects: { account_id: account.id })
        .where(status: "completed")
        .maximum(:completed_at)
    end
  end
end
