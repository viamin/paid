# frozen_string_literal: true

module ProjectConventions
  class DetectForImport
    IMPORT_COLLECTOR_TYPES = [ "project_conventions" ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, commit_sha:, branch:)
      @project = project
      @commit_sha = commit_sha
      @branch = branch
    end

    def call
      worktree_service.with_temporary_checkout(commit_sha) do |checkout_path|
        Knowledge::CollectorRunner.call(
          project: project,
          commit_sha: commit_sha,
          branch: branch,
          options: {
            collector_types: IMPORT_COLLECTOR_TYPES,
            scan_path: checkout_path
          }
        )
      end
    end

    private

    attr_reader :project, :commit_sha, :branch

    def worktree_service
      @worktree_service ||= WorktreeService.new(project)
    end
  end
end
