# frozen_string_literal: true

module Projects
  module Readiness
    # Persists an already-evaluated checkout snapshot. Inbox consumers read
    # this state rather than acquiring a checkout or evaluating during render.
    # @spec PROJECT-READINESS-006
    class Record
      def self.call(...)
        new(...).call
      end

      def initialize(project:, repo_path:)
        @project = project
        @repo_path = repo_path
      end

      def call
        result = Readiness.call(project:, repo_path:)
        gaps = JSON.parse(result.gaps.map(&:to_h).to_json)
        changed = project.readiness_gaps != gaps
        project.update!(readiness_gaps: gaps, readiness_evaluated_at: result.evaluated_at)
        Dashboard::CacheVersion.bump(project.account, scope: Dashboard::CacheVersion::INBOX_SCOPE) if changed
        result
      end

      private

      attr_reader :project, :repo_path
    end
  end
end
