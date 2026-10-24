# frozen_string_literal: true

module Projects
  module Readiness
    # Interface every ecosystem detector implements. Adding support for a
    # new ecosystem means subclassing this and registering the subclass in
    # {Detectors::REGISTRY} — never editing a central language switch.
    class Detector
      # @param project [Project]
      # @param repo_path [String] path to a repository checkout
      # @return [Boolean] whether this detector owns the project's ecosystem
      def self.applicable?(project:, repo_path:)
        raise NotImplementedError
      end

      def initialize(project:, repo_path:)
        @project = project
        @repo_path = repo_path
      end

      # @return [String] identifier recorded in gap evidence (e.g. "ruby", "godot")
      def ecosystem
        raise NotImplementedError
      end

      # @return [Boolean] whether a conventional test directory exists
      def test_directory?
        raise NotImplementedError
      end

      # @return [Array<String>] directory names this detector looked for
      def test_directory_candidates
        raise NotImplementedError
      end

      # @return [Boolean] whether a repository-owned test command is configured
      def test_command_configured?
        raise NotImplementedError
      end

      private

      attr_reader :project, :repo_path
    end
  end
end
