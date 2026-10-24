# frozen_string_literal: true

module FeatureIntents
  # Lists configured design artifacts at an immutable repository revision.
  # Complete discovery is distinct from unavailable coverage so reconciliation
  # can safely retire only findings disproven by repository evidence.
  # @spec DESIGN-RECONCILIATION-001
  class DiscoverRdrArtifacts
    Artifact = Data.define(:path, :revision, :body)
    Discovery = Data.define(:artifacts, :revision, :coverage_complete, :directory_status) do
      def complete? = coverage_complete
    end

    DEFAULT_DIRECTORY = "docs/rdrs"
    DEFAULT_FILE_PATTERN = "RDR-*.md"

    Convention = Data.define(:directory, :file_pattern)

    def self.call(...) = new(...).call

    def self.convention_for(project)
      configured = project.effective_repo_profile.fetch("rdr_convention", {})
      Convention.new(
        directory: configured.fetch("directory", DEFAULT_DIRECTORY),
        file_pattern: configured.fetch("file_pattern", DEFAULT_FILE_PATTERN)
      )
    end

    def initialize(project:)
      @project = project
    end

    def call
      revision = branch_revision
      return unavailable_discovery unless revision

      tree = repository_tree(revision)
      return unavailable_discovery(revision) unless complete_tree?(tree)

      entries = Array(tree.tree)
      artifacts = entries.filter_map { |entry| artifact_for(entry, revision) }
      Discovery.new(
        artifacts:,
        revision:,
        coverage_complete: true,
        directory_status: directory_status(entries, artifacts)
      )
    end

    private

    attr_reader :project

    def convention
      @convention ||= self.class.convention_for(project)
    end

    def branch_revision
      project.client.ref(project.full_name, "heads/#{project.default_branch}").object.sha
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def repository_tree(revision)
      project.client.tree(project.full_name, revision, recursive: true)
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def complete_tree?(tree)
      tree.present? && tree.respond_to?(:tree) && !tree.tree.nil? && !(tree.respond_to?(:truncated) && tree.truncated)
    end

    def unavailable_discovery(revision = project.default_branch)
      Discovery.new(
        artifacts: [ Artifact.new(path: convention.directory, revision:, body: nil) ],
        revision:,
        coverage_complete: false,
        directory_status: :unavailable
      )
    end

    def directory_status(entries, artifacts)
      return :matching_files if artifacts.any?
      return :absent unless entries.any? { |entry| entry.path == convention.directory || entry.path.start_with?("#{convention.directory}/") }
      return :empty if entries.any? { |entry| entry.path == convention.directory && entry.type == "tree" }

      :no_matching_files
    end

    def artifact_for(entry, revision)
      return unless entry.type == "blob" && File.dirname(entry.path) == convention.directory
      return unless File.fnmatch?(convention.file_pattern, File.basename(entry.path))

      Artifact.new(path: entry.path, revision:, body: body_for(entry.path, revision))
    end

    def body_for(path, revision)
      project.client.file_content(project.full_name, path:, ref: revision)
    rescue GithubClient::Error, Faraday::Error
      nil
    end
  end
end
