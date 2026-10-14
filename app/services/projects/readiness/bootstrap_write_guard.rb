# frozen_string_literal: true

module Projects
  module Readiness
    # The bootstrap harness boundary is intentionally independent of
    # Tdd::WriteGuard: it permits only repository plumbing needed before a
    # red/green TDD run can begin.
    # @spec PROJECT-READINESS-008
    class BootstrapWriteGuard
      ALLOWED_EXACT_PATHS = %w[
        .gitlab-ci.yml
        project.godot
        package.json
        yarn.lock
        go.mod
        go.sum
        Gemfile
        Gemfile.lock
        Cargo.toml
        Cargo.lock
        pyproject.toml
        requirements.txt
        .tool-versions
        .rubocop.yml
        eslint.config.js
        eslint.config.mjs
        jest.config.js
        vitest.config.js
      ].freeze
      ALLOWED_PREFIXES = %w[
        .github/workflows/
        .circleci/
        addons/gdUnit4/
        spec/
        test/
        tests/
        __tests__/
        Tests/
      ].freeze
      REASON = "bootstrap runs may only change harness configuration and test layout"

      Result = Data.define(:valid?, :forbidden_files, :reason)

      def self.call(...)
        new(...).call
      end

      def initialize(changed_files:)
        @changed_files = Array(changed_files)
      end

      def call
        forbidden = changed_files.reject { |path| allowed?(path) }.freeze
        Result.new(valid?: forbidden.empty?, forbidden_files: forbidden, reason: REASON)
      end

      private

      attr_reader :changed_files

      def allowed?(path)
        ALLOWED_EXACT_PATHS.include?(path) || ALLOWED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
      end
    end
  end
end
