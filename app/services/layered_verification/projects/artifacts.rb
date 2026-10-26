# frozen_string_literal: true

module LayeredVerification
  module Projects
    # Inventory of the artifacts a project actually has at a revision: a
    # formal model with its config pair, specifications, and tests.
    #
    # The inventory is structural — it reads the repository tree. It never
    # judges whether an artifact is adequate, and a project without a formal
    # model simply has none.
    #
    # @spec LAYERED-VERIFY-021 @spec LAYERED-VERIFY-022
    class Artifacts
      MAX_PATHS = 50
      SPECIFICATION_PREFIXES = %w[docs/intent/ spec/ specs/].freeze
      TEST_PREFIXES = %w[spec/ test/ tests/].freeze

      def self.call(...)
        new(...).call
      end

      def initialize(project:, revision:, client: nil)
        @project = project
        @revision = revision
        @client = client
      end

      def call
        {
          "formal_model" => formal_model,
          "specifications" => paths_under(SPECIFICATION_PREFIXES),
          "tests" => paths_under(TEST_PREFIXES)
        }
      end

      private

      attr_reader :client, :project, :revision

      def formal_model
        model = model_paths.first
        return unless model

        directory = File.dirname(model)
        module_name = File.basename(model, ".tla")
        config = "#{module_name}.cfg"

        {
          "module" => module_name,
          "config" => config,
          "directory" => directory == "." ? nil : directory,
          "path" => model,
          "config_present" => tree_paths.include?(File.join(directory, config))
        }
      end

      def model_paths
        @model_paths ||= tree_paths.select { |path| path.end_with?(".tla") }.sort
      end

      def paths_under(prefixes)
        tree_paths.select { |path| prefixes.any? { |prefix| path.start_with?(prefix) } }.sort.first(MAX_PATHS)
      end

      def tree_paths
        @tree_paths ||= begin
          github = client || project.client
          next [] unless github && revision.present?

          github.tree(project.repo, revision, recursive: true).tree.filter_map do |entry|
            path = entry.path.to_s
            path if entry.type.to_s == "blob"
          end
        rescue GithubClient::Error => e
          Rails.logger.warn(
            message: "layered_verification.artifact_inventory_failed",
            project_id: project.id,
            error_class: e.class.name,
            error: e.message
          )
          []
        end
      end
    end
  end
end
