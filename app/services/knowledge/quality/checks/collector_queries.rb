# frozen_string_literal: true

module Knowledge
  module Quality
    module Checks::CollectorQueries
      # Project-version branches that don't correspond to real git refs in
      # the project. Knowledge::SessionSummaries::SyncKnowledgeArtifact and
      # ChangeIntents::SyncKnowledgeArtifact each create a synthetic
      # ProjectVersion per record (commit_sha = SHA1 of a string, branch =
      # this constant) so they can piggy-back on the collector-run /
      # project-version infrastructure without referencing a real commit.
      # Quality checks that compare against "latest HEAD" must exclude
      # these branches — comparing a git ref to a synthetic SHA produces
      # findings that point at a commit that will never exist in git.
      # Derived from each producer's own `SYNTHETIC_BRANCH` constant so a
      # new synthetic producer can't silently reintroduce this.
      SYNTHETIC_BRANCHES = [
        ChangeIntents::SyncKnowledgeArtifact::SYNTHETIC_BRANCH,
        Knowledge::SessionSummaries::SyncKnowledgeArtifact::SYNTHETIC_BRANCH
      ].freeze

      private

      def latest_collector_runs_by_type
        @latest_collector_runs_by_type ||= CollectorRun
          .joins(:project_version)
          .includes(:project_version)
          .where(project_versions: { project_id: project.id })
          .select("DISTINCT ON (collector_runs.collector_type) collector_runs.*")
          .order(:collector_type, created_at: :desc)
          .index_by(&:collector_type)
      end

      # The most recently committed real project version. Synthetic
      # versions (Knowledge::SessionSummaries::SyncKnowledgeArtifact,
      # ChangeIntents::SyncKnowledgeArtifact) are excluded so checks that
      # compare "HEAD" against collector runs stay git-vs-git — a synthetic
      # version whose `committed_at` happens to be newer than the last real
      # commit would otherwise become "latest", masking every real collector
      # as stale and pointing each finding at a SHA that does not exist.
      def latest_project_version
        @latest_project_version ||= project.project_versions
          .where.not(committed_at: nil)
          .where.not(branch: SYNTHETIC_BRANCHES)
          .order(committed_at: :desc)
          .first
      end
    end
  end
end
