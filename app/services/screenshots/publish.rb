# frozen_string_literal: true

require "tmpdir"

module Screenshots
  class Publish
    class PublishError < StandardError; end

    # Sibling of each `{route}.png`; the exporter reads a `{route}.trace.zip`
    # captured alongside the screenshot when the capture step recorded a trace.
    TRACE_EXTENSION = ".trace.zip"

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
        upload_screenshot(path)
      end

      previous_artifacts = if uploaded_screenshots.any?
        storage.previous_artifacts(
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
        previous_screenshots: previous_artifacts.transform_values { |formats| formats[:png] }.compact
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

    def upload_screenshot(path)
      route_name = File.basename(path, ".png")
      screenshot = {
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

      screenshot.merge(
        Screenshots::TraceArtifactExporter.call(
          storage: storage,
          org: owner,
          repo: name,
          pr_number: @pr_number,
          commit_sha: @commit_sha,
          route_name: route_name,
          trace_path: trace_path_for(path),
          logger: Rails.logger,
          log_message: "screenshots.publish.export_failed",
          log_context: {
            repo: @repo,
            pr_number: @pr_number,
            commit_sha: @commit_sha
          }
        )
      )
    end

    # Resolves a Playwright trace recorded alongside `screenshot_path`, if any.
    # Returns nil when no trace is present, so the exporter falls back to the
    # static PNG.
    def trace_path_for(screenshot_path)
      trace_path = "#{File.dirname(screenshot_path)}/#{File.basename(screenshot_path, '.png')}#{TRACE_EXTENSION}"
      File.exist?(trace_path) ? trace_path : nil
    end
  end
end
