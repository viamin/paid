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

      def collect_findings(collector)
        return if tracked_files.empty?

        # Filesystem check filters out matches per-row, so we can't use the
        # count-then-load shortcut. Bound work instead by breaking out once
        # the collector is at capacity — further iteration would only add
        # to the omitted bucket and can't surface a new finding.
        KnowledgeArtifact
          .active
          .for_project(project)
          .where.not(scope_path: [ nil, "" ])
          .find_each(batch_size: 200) do |artifact|
            break unless collector.remaining_capacity.positive?
            next if file_exists?(artifact.scope_path)

            add_finding(
              collector,
              target_type: "KnowledgeArtifact",
              target_id: artifact.id,
              artifact_type: artifact.artifact_type,
              detail: "scope_path '#{artifact.scope_path}' not found in HEAD"
            )
          end
      rescue WorktreeService::Error => e
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
