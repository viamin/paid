# frozen_string_literal: true

require "open3"

module Knowledge
  module Staleness
    # Detects when a project's knowledge base is stale by comparing the current
    # HEAD SHA against the last collected version. When staleness is detected,
    # marks affected artifacts as stale and enqueues re-collection.
    #
    # Uses the existing bare repo (via WorktreeService) for git operations —
    # no clone needed, keeping detection fast (~100ms).
    class Detector
      STALENESS_THRESHOLD = ENV.fetch("KNOWLEDGE_STALENESS_THRESHOLD", "1").to_i

      attr_reader :project

      def initialize(project:)
        @project = project
      end

      def self.call(...)
        new(...).call
      end

      # @return [Hash] Detection result with keys :stale, :current_sha,
      #   :last_collected_sha, :changed_files, :stale_artifacts_count,
      #   :collection_enqueued
      def call
        current_sha = fetch_current_sha
        return not_stale_result(current_sha) unless current_sha

        last_version = last_collected_version
        return fresh_project_result(current_sha) unless last_version

        last_sha = last_version.commit_sha
        return not_stale_result(current_sha, last_sha:) if current_sha == last_sha

        commit_distance = commits_between(last_sha, current_sha)
        # commit_distance == 0 with different SHAs indicates a force-push/rewind
        # (new_sha is an ancestor of old_sha), which should be treated as stale.
        return not_stale_result(current_sha, last_sha:) if commit_distance.positive? && commit_distance < STALENESS_THRESHOLD

        changed_files = changed_files_between(last_sha, current_sha)
        stale_count = mark_stale_artifacts(changed_files, last_version)
        enqueued = enqueue_recollection(current_sha)

        {
          stale: true,
          current_sha: current_sha,
          last_collected_sha: last_sha,
          changed_files: changed_files,
          stale_artifacts_count: stale_count,
          collection_enqueued: enqueued
        }
      end

      private

      # Fetch from remote before reading HEAD so we detect remote advances.
      # ensure_cloned is a lightweight no-op when the bare repo already exists
      # (just runs `git fetch --all --prune`).
      def fetch_current_sha
        worktree_service.ensure_cloned
        worktree_service.current_commit_sha
      rescue WorktreeService::Error, Errno::ENOENT
        nil
      end

      def last_collected_version
        ProjectVersion
          .for_project(project)
          .joins(:collector_runs)
          .merge(CollectorRun.completed)
          .by_recency
          .first
      end

      def commits_between(old_sha, new_sha)
        output = run_git("rev-list", "--count", "#{old_sha}..#{new_sha}")
        output.strip.to_i
      rescue WorktreeService::Error
        # If we can't count, assume stale to be safe
        STALENESS_THRESHOLD
      end

      def changed_files_between(old_sha, new_sha)
        output = run_git("diff", "--name-only", "#{old_sha}..#{new_sha}")
        output.split("\n").map(&:strip).reject(&:empty?)
      rescue WorktreeService::Error
        []
      end

      def mark_stale_artifacts(changed_files, last_version = last_collected_version)
        return 0 if changed_files.empty? || last_version.nil?

        ActiveRecord::Base.transaction do
          # Scope to artifacts from the last collected version to avoid
          # accidentally staling artifacts from an in-progress collection.
          stale_artifacts = KnowledgeArtifact
            .joins(:collector_run)
            .where(collector_runs: { project_version_id: last_version.id })
            .where(project: project, status: "active")
            .where(scope_path: changed_files)

          return 0 unless stale_artifacts.exists?

          KnowledgeChunk
            .where(knowledge_artifact_id: stale_artifacts.select(:id), status: "active")
            .update_all(status: "stale", updated_at: Time.current)

          stale_artifacts.update_all(status: "stale", updated_at: Time.current)
        end
      end

      def enqueue_recollection(current_sha)
        return false if recently_collected?(current_sha)

        RunCollectorsJob.perform_later(
          project.id,
          current_sha,
          branch: project.default_branch
        )
        true
      end

      def recently_collected?(sha)
        version = ProjectVersion.find_by(
          project: project,
          commit_sha: sha
        )
        return false unless version

        CollectorRun.exists?(project_version_id: version.id)
      end

      def worktree_service
        @worktree_service ||= WorktreeService.new(project)
      end

      def run_git(*args)
        repo_path = File.join(
          WorktreeService.workspace_root,
          project.account_id.to_s,
          project.id.to_s,
          "repo"
        )

        stdout, stderr, status = Open3.capture3("git", *args, chdir: repo_path)

        unless status.success?
          raise WorktreeService::Error, "Git command failed: git #{args.join(" ")}\n#{stderr}"
        end

        stdout
      rescue Errno::ENOENT => e
        raise WorktreeService::Error, "Repo directory missing: #{e.message}"
      end

      def not_stale_result(current_sha, last_sha: nil)
        {
          stale: false,
          current_sha: current_sha,
          last_collected_sha: last_sha,
          changed_files: [],
          stale_artifacts_count: 0,
          collection_enqueued: false
        }
      end

      def fresh_project_result(current_sha)
        enqueued = enqueue_recollection(current_sha)
        {
          stale: false,
          current_sha: current_sha,
          last_collected_sha: nil,
          changed_files: [],
          stale_artifacts_count: 0,
          collection_enqueued: enqueued
        }
      end
    end
  end
end
