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
        GDUNIT4_COMMAND_PATH = "#{GDUNIT4_ADDON_PATH}/bin/GdUnitCmdTool.gd"
        TEST_COMMAND_PATH = "bin/test"
        INSTALL_COMMAND_PATH = "bin/install-test-tools"

        TestCommandConfiguration = Data.define(:status) do
          def configured?
            status.in?(%i[installed setup_required])
          end
        end

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
          # @spec PROJECT-READINESS-013
          test_command_configuration.configured?
        end

        def test_command_description
          "gdUnit4 (#{GDUNIT4_COMMAND_PATH})"
        end

        # @spec PROJECT-READINESS-013
        def test_command_configuration
          return TestCommandConfiguration.new(status: :installed) if installed_command?
          return TestCommandConfiguration.new(status: :setup_required) if install_on_demand?

          TestCommandConfiguration.new(status: :unavailable)
        end

        private

        def installed_command?
          File.file?(File.join(repo_path, GDUNIT4_COMMAND_PATH))
        end

        def install_on_demand?
          executable_file?(TEST_COMMAND_PATH) && executable_file?(INSTALL_COMMAND_PATH)
        end

        def executable_file?(relative_path)
          path = File.join(repo_path, relative_path)
          File.file?(path) && File.executable?(path)
        end
      end
    end
  end
end
