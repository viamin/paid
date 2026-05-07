# frozen_string_literal: true

namespace :screenshots do
  desc "Capture rendered screenshots of key UI pages for PR review. " \
       "Set SCREENSHOT_OUTPUT_DIR to control output location (default: tmp/screenshots). " \
       "Set CHANGED_FILES (newline-separated) to only screenshot when UI files changed."
  task capture: :environment do
    require "screenshots/capture"

    changed_files = ENV.fetch("CHANGED_FILES", "").split("\n").map(&:strip).reject(&:empty?)

    if changed_files.any?
      result = Screenshots::DetectUiChanges.call(changed_files: changed_files)
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

    if comment_status == "capture_failed"
      Screenshots::PrComment.call(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        status: comment_status
      )

      puts "Updated screenshot comment with capture failure for PR ##{pr_number}."
      next
    end

    if comment_status == "no_ui_changes"
      Screenshots::PrComment.call(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        status: comment_status
      )

      puts "Updated screenshot comment to mark screenshots stale for PR ##{pr_number}."
      next
    end

    if screenshot_paths.any? && !Screenshots::Storage.configured?
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

    Screenshots::Publish.call(
      github_client: github_client,
      repo: repo,
      pr_number: pr_number,
      commit_sha: commit_sha,
      screenshot_paths: screenshot_paths
    )

    puts "Published #{screenshot_paths.size} screenshot(s) for PR ##{pr_number}."
  end

  desc "Delete uploaded screenshots for a closed or merged PR"
  task cleanup_pr: :environment do
    repo = ENV.fetch("GITHUB_REPOSITORY")
    pr_number = Integer(ENV.fetch("PR_NUMBER"))
    owner, name = repo.split("/", 2)

    unless owner.present? && name.present?
      raise ArgumentError, "GITHUB_REPOSITORY must be in owner/name format"
    end

    unless Screenshots::Storage.configured?
      puts "Screenshot storage is not configured. Skipping PR cleanup."
      next
    end

    Screenshots::Storage.new.delete_pr_screenshots(org: owner, repo: name, pr_number: pr_number)
    puts "Deleted screenshots for PR ##{pr_number}."
  end

  desc "Delete old uploaded screenshots using the configured retention policy"
  task cleanup_old: :environment do
    retention_days = Integer(ENV.fetch("SCREENSHOT_RETENTION_DAYS", Screenshots::Storage::DEFAULT_RETENTION_DAYS))

    ScreenshotCleanupJob.perform_now(retention_days: retention_days)

    puts "Cleaned up screenshots older than #{retention_days} day(s)."
  end
end
