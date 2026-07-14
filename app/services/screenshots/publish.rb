# frozen_string_literal: true

require "tmpdir"

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

      screenshot.merge(export_artifacts(path, route_name))
    end

    def export_artifacts(path, route_name)
      Dir.mktmpdir("screenshots-publish-export-") do |tmpdir|
        video_path = File.join(tmpdir, "#{route_name}.webm")
        gif_path = File.join(tmpdir, "#{route_name}.gif")

        Screenshots::TraceToVideo.call(frames: [ path ], output_path: video_path)
        Screenshots::TraceToGif.call(frames: [ path ], output_path: gif_path)

        {
          gif_url: storage.upload_artifact(
            file_path: gif_path,
            org: owner,
            repo: name,
            pr_number: @pr_number,
            commit_sha: @commit_sha,
            route_name: route_name
          ),
          video_url: storage.upload_artifact(
            file_path: video_path,
            org: owner,
            repo: name,
            pr_number: @pr_number,
            commit_sha: @commit_sha,
            route_name: route_name
          ),
          video_filename: "#{route_name}.webm"
        }
      end
    rescue Screenshots::TraceToVideo::ConversionError, Screenshots::TraceToGif::ConversionError => e
      Rails.logger.warn(
        message: "screenshots.publish.export_failed",
        repo: @repo,
        pr_number: @pr_number,
        commit_sha: @commit_sha,
        route_name: route_name,
        error: e.message
      )
      {}
    end
  end
end
