# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "screenshots:capture" do
  let(:task) { Rake::Task[task_name] }
  let(:task_name) { "screenshots:capture" }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?(task_name)
    task.reenable
  end

  context "when CHANGED_FILES contains no UI files" do
    around do |example|
      original = ENV["CHANGED_FILES"]
      ENV["CHANGED_FILES"] = "app/models/user.rb\nconfig/routes.rb"
      example.run
    ensure
      ENV["CHANGED_FILES"] = original
    end

    it "skips screenshot capture" do
      expect { task.invoke }.to output(/No UI-facing file changes detected/).to_stdout
    end
  end

  context "when CHANGED_FILES contains UI files" do
    let(:output_dir) { Dir.mktmpdir }

    around do |example|
      original_files = ENV["CHANGED_FILES"]
      original_dir = ENV["SCREENSHOT_OUTPUT_DIR"]
      ENV["CHANGED_FILES"] = "app/views/projects/index.html.erb"
      ENV["SCREENSHOT_OUTPUT_DIR"] = output_dir
      example.run
    ensure
      ENV["CHANGED_FILES"] = original_files
      ENV["SCREENSHOT_OUTPUT_DIR"] = original_dir
      FileUtils.rm_rf(output_dir)
    end

    it "detects UI-facing changes and runs capture" do
      allow(Screenshots::Capture).to receive(:call).and_return([])

      expect { task.invoke }.to output(/Detected 1 UI-facing file change/).to_stdout
      expect(Screenshots::Capture).to have_received(:call).with(
        output_dir: output_dir,
        changed_files: [ "app/views/projects/index.html.erb" ]
      )
    end

    it "passes only UI files to capture when the change list is mixed" do
      ENV["CHANGED_FILES"] = "app/views/projects/index.html.erb\napp/models/project.rb"
      allow(Screenshots::Capture).to receive(:call).and_return([])

      task.invoke

      expect(Screenshots::Capture).to have_received(:call).with(
        output_dir: output_dir,
        changed_files: [ "app/views/projects/index.html.erb" ]
      )
    end
  end

  context "when CHANGED_FILES is empty" do
    let(:output_dir) { Dir.mktmpdir }

    around do |example|
      original_files = ENV["CHANGED_FILES"]
      original_dir = ENV["SCREENSHOT_OUTPUT_DIR"]
      ENV["CHANGED_FILES"] = ""
      ENV["SCREENSHOT_OUTPUT_DIR"] = output_dir
      example.run
    ensure
      ENV["CHANGED_FILES"] = original_files
      ENV["SCREENSHOT_OUTPUT_DIR"] = original_dir
      FileUtils.rm_rf(output_dir)
    end

    it "proceeds with capture without filtering" do
      allow(Screenshots::Capture).to receive(:call).and_return([])

      expect { task.invoke }.to output(/Captured 0 screenshot/).to_stdout
      expect(Screenshots::Capture).to have_received(:call).with(
        output_dir: output_dir,
        changed_files: []
      )
    end
  end

  describe "screenshots:publish" do
    let(:task_name) { "screenshots:publish" }
    let(:output_dir) { Dir.mktmpdir }
    let(:github_client) { instance_double(GithubClient) }

    around do |example|
      original_env = ENV.to_h.slice(
        "GITHUB_REPOSITORY",
        "PR_NUMBER",
        "COMMIT_SHA",
        "GITHUB_TOKEN",
        "SCREENSHOT_OUTPUT_DIR",
        "SCREENSHOT_COMMENT_STATUS"
      )
      ENV["GITHUB_REPOSITORY"] = "acme/web"
      ENV["PR_NUMBER"] = "42"
      ENV["COMMIT_SHA"] = "abc1234def5678"
      ENV["GITHUB_TOKEN"] = "ghp_test"
      ENV["SCREENSHOT_OUTPUT_DIR"] = output_dir
      example.run
    ensure
      FileUtils.rm_rf(output_dir)
      %w[GITHUB_REPOSITORY PR_NUMBER COMMIT_SHA GITHUB_TOKEN SCREENSHOT_OUTPUT_DIR SCREENSHOT_COMMENT_STATUS].each do |key|
        original_env.key?(key) ? ENV[key] = original_env[key] : ENV.delete(key)
      end
    end

    it "publishes screenshots from the output directory" do
      File.write(File.join(output_dir, "dashboard.png"), "png")
      File.write(File.join(output_dir, "homepage.png"), "png")
      allow(GithubClient).to receive(:new).with(token: "ghp_test").and_return(github_client)
      allow(Screenshots::Storage).to receive(:configured?).and_return(true)
      allow(Screenshots::Publish).to receive(:call)

      expect { task.invoke }.to output(/Published 2 screenshot\(s\) for PR #42\./).to_stdout
      expect(Screenshots::Publish).to have_received(:call).with(
        github_client: github_client,
        repo: "acme/web",
        pr_number: 42,
        commit_sha: "abc1234def5678",
        screenshot_paths: [
          File.join(output_dir, "dashboard.png"),
          File.join(output_dir, "homepage.png")
        ]
      )
    end

    it "updates the PR comment even when no screenshots were captured" do
      allow(GithubClient).to receive(:new).with(token: "ghp_test").and_return(github_client)
      allow(Screenshots::Storage).to receive(:configured?).and_return(false)
      allow(Screenshots::Publish).to receive(:call)

      task.invoke

      expect(Screenshots::Publish).to have_received(:call).with(
        github_client: github_client,
        repo: "acme/web",
        pr_number: 42,
        commit_sha: "abc1234def5678",
        screenshot_paths: []
      )
    end

    it "posts artifact fallback instructions when screenshots exist but storage is not configured" do
      File.write(File.join(output_dir, "dashboard.png"), "png")
      allow(GithubClient).to receive(:new).with(token: "ghp_test").and_return(github_client)
      allow(Screenshots::Storage).to receive(:configured?).and_return(false)
      allow(Screenshots::PrComment).to receive(:call)

      expect { task.invoke }
        .to output(/Posted artifact-only screenshot instructions for PR #42\./).to_stdout

      expect(Screenshots::PrComment).to have_received(:call).with(
        github_client: github_client,
        repo: "acme/web",
        pr_number: 42,
        commit_sha: "abc1234def5678",
        screenshots: [],
        artifact_name: "pr-screenshots"
      )
    end

    it "updates the PR comment with a capture failure notice" do
      ENV["SCREENSHOT_COMMENT_STATUS"] = "capture_failed"
      allow(GithubClient).to receive(:new).with(token: "ghp_test").and_return(github_client)
      allow(Screenshots::PrComment).to receive(:call)

      expect { task.invoke }
        .to output(/Updated screenshot comment with capture failure for PR #42\./).to_stdout

      expect(Screenshots::PrComment).to have_received(:call).with(
        github_client: github_client,
        repo: "acme/web",
        pr_number: 42,
        commit_sha: "abc1234def5678",
        screenshots: [],
        status: "capture_failed"
      )
    end

    it "updates the PR comment when the PR no longer has UI changes" do
      ENV["SCREENSHOT_COMMENT_STATUS"] = "no_ui_changes"
      allow(GithubClient).to receive(:new).with(token: "ghp_test").and_return(github_client)
      allow(Screenshots::PrComment).to receive(:call)

      expect { task.invoke }
        .to output(/Updated screenshot comment to mark screenshots stale for PR #42\./).to_stdout

      expect(Screenshots::PrComment).to have_received(:call).with(
        github_client: github_client,
        repo: "acme/web",
        pr_number: 42,
        commit_sha: "abc1234def5678",
        screenshots: [],
        status: "no_ui_changes"
      )
    end
  end

  describe "screenshots:cleanup_pr" do
    let(:task_name) { "screenshots:cleanup_pr" }
    let(:storage) { instance_double(Screenshots::Storage) }

    around do |example|
      original_env = ENV.to_h.slice("GITHUB_REPOSITORY", "PR_NUMBER")
      ENV["GITHUB_REPOSITORY"] = "acme/web"
      ENV["PR_NUMBER"] = "42"
      example.run
    ensure
      %w[GITHUB_REPOSITORY PR_NUMBER].each do |key|
        original_env.key?(key) ? ENV[key] = original_env[key] : ENV.delete(key)
      end
    end

    it "deletes screenshots for the PR" do
      allow(Screenshots::Storage).to receive_messages(configured?: true, new: storage)
      allow(storage).to receive(:delete_pr_screenshots)

      expect { task.invoke }.to output(/Deleted screenshots for PR #42\./).to_stdout
      expect(storage).to have_received(:delete_pr_screenshots).with(org: "acme", repo: "web", pr_number: 42)
    end

    it "skips cleanup when storage is not configured" do
      allow(Screenshots::Storage).to receive(:configured?).and_return(false)
      expect(Screenshots::Storage).not_to receive(:new)

      expect { task.invoke }.to output(/Skipping PR cleanup/).to_stdout
    end
  end

  describe "screenshots:cleanup_old" do
    let(:task_name) { "screenshots:cleanup_old" }

    around do |example|
      original = ENV["SCREENSHOT_RETENTION_DAYS"]
      ENV["SCREENSHOT_RETENTION_DAYS"] = "60"
      example.run
    ensure
      ENV["SCREENSHOT_RETENTION_DAYS"] = original
    end

    it "runs the cleanup job with the configured retention period" do
      allow(ScreenshotCleanupJob).to receive(:perform_now)

      expect { task.invoke }.to output(/older than 60 day\(s\)/).to_stdout
      expect(ScreenshotCleanupJob).to have_received(:perform_now).with(retention_days: 60)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
