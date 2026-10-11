# frozen_string_literal: true

module Projects
  module Readiness
    module Detectors
      # Godot 4.x + gdUnit4. Reference ecosystem for #4256 — `viamin/Forager-iOS`
      # has no `project.godot` yet (greenfield), so applicability also checks
      # the project's detected language (GitHub reports GDScript repos as
      # such) rather than relying solely on repo-tree markers.
      class Godot < Detector
        LANGUAGE_KEYS = %w[gdscript godot].freeze
        PROJECT_MARKER = "project.godot"
        TEST_DIR_CANDIDATES = %w[test tests].freeze
        GDUNIT4_ADDON_PATH = "addons/gdUnit4"

        def self.applicable?(project:, repo_path:)
          LANGUAGE_KEYS.include?(Prompts::LanguageCommands.detected_language(project)) ||
            File.file?(File.join(repo_path, PROJECT_MARKER))
        end

        def ecosystem
          "godot"
        end

        def test_directory_candidates
          TEST_DIR_CANDIDATES
        end

        def test_directory?
          test_directory_candidates.any? { |dir| Dir.exist?(File.join(repo_path, dir)) }
        end

        def test_command_configured?
          Dir.exist?(File.join(repo_path, GDUNIT4_ADDON_PATH))
        end

        def test_command_description
          "gdUnit4 (#{GDUNIT4_ADDON_PATH})"
        end
      end
    end
  end
end
