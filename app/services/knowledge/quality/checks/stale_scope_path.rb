# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active artifacts whose scope_path no longer exists in HEAD. Skips
    # artifacts without a scope_path (e.g. derived collections like language
    # stats). The check is conservative: by default it inspects the bare
    # repository through `WorktreeService`; environments without git access
    # report zero findings rather than guessing.
    class Checks::StaleScopePath < Checks::Base
      code "stale_scope_path"
      severity "warning"

      def findings
        results = []

        KnowledgeArtifact
          .active
          .for_project(project)
          .where.not(scope_path: [ nil, "" ])
          .find_each(batch_size: 200) do |artifact|
            next if file_exists?(artifact.scope_path)

            results << build_finding(
              target_type: "KnowledgeArtifact",
              target_id: artifact.id,
              artifact_type: artifact.artifact_type,
              detail: "scope_path '#{artifact.scope_path}' not found in HEAD"
            )
          end

        results
      rescue WorktreeService::Error, StandardError => e
        Rails.logger.debug(
          message: "knowledge.quality.stale_scope_path.skipped",
          project_id: project.id,
          error: e.message
        )
        []
      end

      # Exposed for tests so they can stub filesystem access without monkey-
      # patching the worktree service.
      def file_exists?(scope_path)
        tracked_files.include?(scope_path)
      end

      private

      # Lists HEAD's tree once per check run instead of spawning a `git
      # cat-file` subprocess per artifact — the difference between one
      # process and thousands on a project with many scoped artifacts.
      def tracked_files
        @tracked_files ||= worktree_service.tracked_files
      end

      def worktree_service
        @worktree_service ||= WorktreeService.new(project)
      end
    end
  end
end
