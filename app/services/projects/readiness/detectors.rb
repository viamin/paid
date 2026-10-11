# frozen_string_literal: true

module Projects
  module Readiness
    module Detectors
      # Checked in order; the first applicable detector wins. Ecosystem-specific
      # detectors (e.g. Godot) come before the universal LanguageCommands
      # fallback so a project with a more precise match isn't swallowed by it.
      REGISTRY = [
        Godot,
        LanguageCommands
      ].freeze

      def self.applicable_for(project:, repo_path:)
        detector_class = REGISTRY.find { |candidate| candidate.applicable?(project: project, repo_path: repo_path) }
        detector_class.new(project: project, repo_path: repo_path)
      end
    end
  end
end
