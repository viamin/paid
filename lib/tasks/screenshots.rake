# frozen_string_literal: true

namespace :screenshots do
  desc "Capture rendered screenshots of key UI pages for PR review. " \
       "Set SCREENSHOT_OUTPUT_DIR to control output location (default: tmp/screenshots). " \
       "Set CHANGED_FILES (newline-separated) to only screenshot when UI files changed."
  task capture: :environment do
    require "screenshots/capture"

    changed_files = ENV.fetch("CHANGED_FILES", "").split("\n").map(&:strip).reject(&:empty?)
    project = Project.find_by(id: ENV["PROJECT_ID"]) if ENV["PROJECT_ID"].present?

    if changed_files.any?
      ui_detection_options = { repo_path: Dir.pwd }
      ui_detection_options.merge!(
        Screenshots::ConfigParser.ui_detection_overrides(project:, repo_path: Dir.pwd)
      )

      result = Screenshots::DetectUiChanges.call(
        changed_files: changed_files,
        **ui_detection_options
      )
      unless result[:ui_changes?]
        puts "No UI-facing file changes detected. Skipping screenshot capture."
        next
      end
      changed_files = result[:ui_files]
      puts "Detected #{result[:ui_files].size} UI-facing file change(s):"
      result[:ui_files].each { |f| puts "  #{f}" }
    end

    output_dir = ENV.fetch("SCREENSHOT_OUTPUT_DIR", "tmp/screenshots")
    screenshots = Screenshots::Capture.call(output_dir: output_dir, changed_files: changed_files)

    puts "\nCaptured #{screenshots.size} screenshot(s) in #{output_dir}/"
    screenshots.each { |path| puts "  #{path}" }
  end

  desc "Upload captured screenshots to object storage and post/update the PR comment"
  task publish: :environment do
    repo = ENV.fetch("GITHUB_REPOSITORY")
    pr_number = Integer(ENV.fetch("PR_NUMBER"))
    commit_sha = ENV.fetch("COMMIT_SHA")
    github_token = ENV.fetch("GITHUB_TOKEN")
    screenshot_dir = ENV.fetch("SCREENSHOT_OUTPUT_DIR", "tmp/screenshots")
    comment_status = ENV.fetch("SCREENSHOT_COMMENT_STATUS", "success")
    screenshot_paths = Dir.glob(File.join(screenshot_dir, "*.png")).sort
    github_client = GithubClient.new(token: github_token)
    post_status_comment = lambda do |status, message|
      Screenshots::PrComment.call(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        status: status
      )

      puts message
    end

    if comment_status == "capture_failed"
      post_status_comment.call("capture_failed", "Updated screenshot comment with capture failure for PR ##{pr_number}.")
      next
    end

    if comment_status == "no_ui_changes"
      post_status_comment.call("no_ui_changes", "Updated screenshot comment to mark screenshots stale for PR ##{pr_number}.")
      next
    end

    if Screenshots::Storage.configured?
      begin
        Screenshots::Publish.call(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshot_paths: screenshot_paths
        )

        puts "Published #{screenshot_paths.size} screenshot(s) for PR ##{pr_number}."
        next
      rescue StandardError
        post_status_comment.call("capture_failed", "Updated screenshot comment with capture failure for PR ##{pr_number}.")
        raise
      end
    end

    if Screenshots::BranchStorage.configured? && screenshot_paths.any?
      begin
        branch_storage = Screenshots::BranchStorage.new(
          repo: repo,
          github_token: Screenshots::BranchStorage.token
        )
        screenshots = branch_storage.upload_all(
          screenshot_paths: screenshot_paths,
          pr_number: pr_number,
          commit_sha: commit_sha
        )
        previous = branch_storage.previous_screenshots(
          pr_number: pr_number,
          exclude_sha: commit_sha,
          github_client: github_client
        )

        Screenshots::PrComment.call(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: screenshots,
          previous_screenshots: previous
        )

        puts "Published #{screenshot_paths.size} screenshot(s) to branch for PR ##{pr_number}."
        next
      rescue Screenshots::BranchStorage::PushError => e
        Rails.logger.warn(
          message: "screenshots.branch_push_failed",
          pr_number: pr_number,
          error: e.message
        )
      end
    end

    if screenshot_paths.any?
      Screenshots::PrComment.call(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        artifact_name: "pr-screenshots"
      )

      puts "Posted artifact-only screenshot instructions for PR ##{pr_number}."
      next
    end

    Screenshots::PrComment.call(
      github_client: github_client,
      repo: repo,
      pr_number: pr_number,
      commit_sha: commit_sha,
      screenshots: []
    )
  end

  desc "Delete uploaded screenshots for a closed or merged PR"
  task cleanup_pr: :environment do
    repo = ENV.fetch("GITHUB_REPOSITORY")
    pr_number = Integer(ENV.fetch("PR_NUMBER"))
    owner, name = repo.split("/", 2)

    unless owner.present? && name.present?
      raise ArgumentError, "GITHUB_REPOSITORY must be in owner/name format"
    end

    cleaned = false

    if Screenshots::Storage.configured?
      Screenshots::Storage.new.delete_pr_screenshots(org: owner, repo: name, pr_number: pr_number)
      cleaned = true
    end

    if Screenshots::BranchStorage.configured?
      Screenshots::BranchStorage.new(repo: repo, github_token: Screenshots::BranchStorage.token)
        .delete_pr_screenshots(pr_number: pr_number)
      cleaned = true
    end

    if cleaned
      puts "Deleted screenshots for PR ##{pr_number}."
    else
      puts "No screenshot storage configured. Skipping PR cleanup."
    end
  end

  desc "Delete old uploaded screenshots using the configured retention policy"
  task cleanup_old: :environment do
    retention_days = Integer(ENV.fetch("SCREENSHOT_RETENTION_DAYS", Screenshots::Storage::DEFAULT_RETENTION_DAYS))

    ScreenshotCleanupJob.perform_now(retention_days: retention_days)

    puts "Cleaned up screenshots older than #{retention_days} day(s)."
  end
end
