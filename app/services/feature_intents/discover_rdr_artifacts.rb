# frozen_string_literal: true

module FeatureIntents
  # Lists conventional RDR files at the project's configured branch. File SHA
  # makes each reconciliation finding refer to an immutable document revision.
  # @spec DESIGN-RECONCILIATION-001
  class DiscoverRdrArtifacts
    Artifact = Data.define(:path, :revision, :body)

    RDRS_PATH = "docs/rdrs"
    RDR_PATH = %r{\Adocs/rdrs/RDR-\d+-.+\.md\z}

    def self.call(...) = new(...).call

    def initialize(project:)
      @project = project
    end

    def call
      return [ unverifiable_artifact ] unless entries

      entries.filter_map { |entry| artifact_for(entry) }
    end

    private

    attr_reader :project

    def entries
      Array(project.client.contents(project.full_name, path: RDRS_PATH, ref: project.default_branch))
    rescue GithubClient::Error
      nil
    end

    def unverifiable_artifact
      Artifact.new(path: RDRS_PATH, revision: project.default_branch, body: nil)
    end

    def artifact_for(entry)
      return unless entry.type == "file" && entry.path.match?(RDR_PATH)

      Artifact.new(path: entry.path, revision: entry.sha, body: body_for(entry.path))
    end

    def body_for(path)
      project.client.file_content(project.full_name, path:, ref: project.default_branch)
    rescue GithubClient::Error
      nil
    end
  end
end
