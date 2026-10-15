# frozen_string_literal: true

module FeatureIntents
  # Lists RDR files using the project's configured convention. File SHA
  # makes each reconciliation finding refer to an immutable document revision.
  # @spec DESIGN-RECONCILIATION-001
  class DiscoverRdrArtifacts
    Artifact = Data.define(:path, :revision, :body)

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
      return [ unverifiable_artifact ] unless revision

      listed_entries = entries(revision)
      return [ unverifiable_artifact ] unless listed_entries

      listed_entries.filter_map { |entry| artifact_for(entry, revision) }
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

    def entries(revision)
      Array(project.client.contents(project.full_name, path: convention.directory, ref: revision))
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def unverifiable_artifact
      Artifact.new(path: convention.directory, revision: project.default_branch, body: nil)
    end

    def artifact_for(entry, revision)
      return unless entry.type == "file" && File.dirname(entry.path) == convention.directory
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
