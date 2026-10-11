# frozen_string_literal: true

module Projects
  module Readiness
    # Runs every readiness rule against a project/repo-checkout pair and
    # collects the gaps they report. Adding a new settings-aware rule means
    # appending it to RULES — this class does not branch on settings itself.
    class Evaluate
      RULES = [ Rules::Tdd ].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(project:, repo_path:)
        @project = project
        @repo_path = repo_path
      end

      def call
        gaps = RULES.flat_map { |rule| rule.call(project: project, repo_path: repo_path) }
        Result.new(gaps: gaps, evaluated_at: Time.current)
      end

      private

      attr_reader :project, :repo_path
    end
  end
end
