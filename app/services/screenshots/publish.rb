# frozen_string_literal: true

module Screenshots
  class Publish
    class PublishError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(github_client:, repo:, pr_number:, commit_sha:, screenshot_paths:, storage: nil)
      @github_client = github_client
      @repo = repo
      @pr_number = pr_number
      @commit_sha = commit_sha
      @screenshot_paths = screenshot_paths
      @storage = storage
    end

    def call
      uploaded_screenshots = screenshot_paths.map do |path|
        route_name = File.basename(path, ".png")

        {
          route_name: route_name,
          url: storage.upload(
            file_path: path,
            org: owner,
            repo: name,
            pr_number: @pr_number,
            commit_sha: @commit_sha,
            route_name: route_name
          )
        }
      end

      previous = if uploaded_screenshots.any?
        storage.previous_screenshots(
          org: owner,
          repo: name,
          pr_number: @pr_number,
          exclude_sha: @commit_sha
        )
      else
        {}
      end

      Screenshots::PrComment.call(
        github_client: @github_client,
        repo: @repo,
        pr_number: @pr_number,
        commit_sha: @commit_sha,
        screenshots: uploaded_screenshots,
        previous_screenshots: previous
      )
    end

    private

    attr_reader :screenshot_paths

    def owner
      repo_parts.fetch(0)
    end

    def name
      repo_parts.fetch(1)
    end

    def repo_parts
      @repo_parts ||= begin
        parts = @repo.split("/", 2)
        raise PublishError, "repo must be in owner/name format" unless parts.size == 2 && parts.all?(&:present?)

        parts
      end
    end

    def storage
      @storage ||= Screenshots::Storage.new
    end
  end
end
