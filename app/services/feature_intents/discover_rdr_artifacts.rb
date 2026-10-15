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
      revision = branch_revision
      return [ unverifiable_artifact ] unless revision

      listed_entries = entries(revision)
      return [ unverifiable_artifact ] unless listed_entries

      listed_entries.filter_map { |entry| artifact_for(entry, revision) }
    end

    private

    attr_reader :project

    def branch_revision
      project.client.ref(project.full_name, "heads/#{project.default_branch}").object.sha
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def entries(revision)
      Array(project.client.contents(project.full_name, path: RDRS_PATH, ref: revision))
    rescue GithubClient::Error, Faraday::Error
      nil
    end

    def unverifiable_artifact
      Artifact.new(path: RDRS_PATH, revision: project.default_branch, body: nil)
    end

    def artifact_for(entry, revision)
      return unless entry.type == "file" && entry.path.match?(RDR_PATH)

      Artifact.new(path: entry.path, revision:, body: body_for(entry.path, revision))
    end

    def body_for(path, revision)
      project.client.file_content(project.full_name, path:, ref: revision)
    rescue GithubClient::Error, Faraday::Error
      nil
    end
  end
end
