# frozen_string_literal: true

module Projects
  module Readiness
    module Rules
      # @spec PROJECT-READINESS-002 @spec PROJECT-READINESS-003
      #
      # `tdd_mode: strict` and `tdd_mode: non_strict` both require a
      # CI-capable repo, a conventional test directory, and a configured test
      # command before a red-phase (failing-CI) draft PR is possible.
      # `tdd_mode: off` adds no prerequisites — additive-safe for projects
      # that never asked for TDD enforcement.
      class Tdd
        CI_MARKERS = %w[.github/workflows .circleci/config.yml .gitlab-ci.yml].freeze
        GAP_KINDS = %w[missing_ci missing_test_directory missing_test_command].freeze
        REQUIRING_MODES = %w[strict non_strict].freeze

        def self.call(...)
          new(...).call
        end

        def initialize(project:, repo_path:)
          @project = project
          @repo_path = repo_path
        end

        def call
          return [] unless REQUIRING_MODES.include?(project.tdd_mode)

          [ ci_gap, test_directory_gap, test_command_gap ].compact
        end

        private

        attr_reader :project, :repo_path

        def detector
          @detector ||= Readiness::Detectors.applicable_for(project: project, repo_path: repo_path)
        end

        def ci_gap
          return if ci_present?

          Gap.new(
            kind: GAP_KINDS.first,
            description: "tdd_mode: #{project.tdd_mode} requires a CI-capable repository " \
              "(.github/workflows/ or equivalent) to run the red/green test cycle.",
            evidence: { checked_paths: CI_MARKERS }
          )
        end

        def ci_present?
          CI_MARKERS.any? { |relative| marker_present?(relative) }
        end

        def marker_present?(relative_path)
          full_path = File.join(repo_path, relative_path)
          File.directory?(full_path) ? Dir.children(full_path).any? : File.file?(full_path)
        end

        def test_directory_gap
          return if detector.test_directory?

          Gap.new(
            kind: GAP_KINDS.second,
            description: "tdd_mode: #{project.tdd_mode} requires a #{detector.ecosystem} test directory.",
            evidence: { ecosystem: detector.ecosystem, checked_paths: detector.test_directory_candidates }
          )
        end

        def test_command_gap
          return if detector.test_command_configured?

          Gap.new(
            kind: GAP_KINDS.third,
            description: "tdd_mode: #{project.tdd_mode} requires a runnable #{detector.ecosystem} test command.",
            evidence: { ecosystem: detector.ecosystem }
          )
        end
      end
    end
  end
end
