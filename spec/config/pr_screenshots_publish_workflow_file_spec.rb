# frozen_string_literal: true

require "rails_helper"
require "psych"

class PrScreenshotsPublishWorkflowFile < Pathname
end

RSpec.describe PrScreenshotsPublishWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/pr-screenshots-publish.yml"),
      aliases: true
    )
  end

  def job
    workflow.fetch("jobs").fetch("publish")
  end

  def job_env
    job.fetch("env")
  end

  def step(name)
    job.fetch("steps").find { |job_step| job_step["name"] == name }
  end

  def checkout_step
    step("Checkout trusted base-branch code")
  end

  def resolve_step
    step("Resolve PR capture run")
  end

  def resolve_env
    resolve_step.fetch("env")
  end

  def publish_step
    step("Publish screenshots and refresh PR comment")
  end

  def publish_env
    publish_step.fetch("env")
  end

  it "scopes concurrency by PR number and action to avoid cross-event self-cancellation" do
    expect(workflow.fetch("concurrency")).to include(
      "group" => "pr-screenshots-publish-${{ github.event.pull_request.number }}-${{ github.event.action }}",
      "cancel-in-progress" => true
    )
  end

  it "pins the checkout to the trusted base sha before loading Rails with secrets" do
    expect(checkout_step).to be_present
    expect(checkout_step.fetch("with")).to include("ref" => "${{ github.event.pull_request.base.sha }}")
  end

  it "boots Rails in test mode against the workflow postgres service before publishing" do
    expect(job.fetch("services").fetch("postgres")).to include(
      "image" => "postgres:16.14",
      "ports" => [ "5432:5432" ]
    )

    expect(job_env).to include(
      "RAILS_ENV" => "test",
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_TEST_DATABASE" => "paid_test",
      "DB_HOST" => "localhost",
      "DB_USERNAME" => "postgres",
      "DB_PASSWORD" => "postgres",
      "TMPDIR" => "${{ github.workspace }}/.tmp-build",
      "YARN_CACHE_FOLDER" => "${{ github.workspace }}/.cache-yarn",
      "XDG_CACHE_HOME" => "${{ github.workspace }}/.cache",
      "npm_config_cache" => "${{ github.workspace }}/.cache/npm",
      "PLAYWRIGHT_BROWSERS_PATH" => "${{ github.workspace }}/.cache/ms-playwright",
      "RAILS_MASTER_KEY_FALLBACK" => "${{ secrets.RAILS_MASTER_KEY }}"
    )
  end

  it "normalizes the fallback key and prepares the schema-only test database before publishing" do
    expect(step("Normalize test master key")).to include("if" => "env.RAILS_TEST_KEY == ''")
    expect(step("Normalize test master key").fetch("run")).to include(
      'echo "RAILS_TEST_KEY=$RAILS_MASTER_KEY_FALLBACK" >> "$GITHUB_ENV"'
    )
    expect(step("Prepare workspace cache directories").fetch("run")).to eq(
      'mkdir -p "$TMPDIR" "$YARN_CACHE_FOLDER" "$XDG_CACHE_HOME" "$npm_config_cache" "$PLAYWRIGHT_BROWSERS_PATH"'
    )
    expect(step("Set up database").fetch("run")).to eq("bin/rails db:create db:schema:load")
    expect(step("Bootstrap test defaults").fetch("run")).to eq("bin/rails ci:bootstrap_test_defaults")
  end

  it "queries recent screenshot capture runs without relying on GitHub branch filtering" do
    expect(resolve_step.fetch("run")).to include("runs?event=pull_request&per_page=100")
    expect(resolve_step.fetch("run")).not_to include("branch=\#{head_ref}")
  end

  it "passes the PR head ref to the resolver for branch-based lookup and fallback matching" do
    expect(resolve_env).to include(
      "HEAD_REF" => "${{ github.event.pull_request.head.ref }}",
      "PR_UPDATED_AT" => "${{ github.event.pull_request.updated_at }}"
    )
    expect(resolve_step.fetch("run")).to include("poll_attempts = 120")
    expect(resolve_step.fetch("run")).to include("poll_interval_seconds = 10")
    expect(resolve_step.fetch("run")).to include("recent_window_seconds = 300")
    expect(resolve_step.fetch("run")).to include("poll_search_pages = 5")
    expect(resolve_step.fetch("run")).to include("fallback_search_pages = 30")
    expect(resolve_step.fetch("run")).to include('candidate["head_sha"] == head_sha || candidate.dig("head_commit", "id") == head_sha')
    expect(resolve_step.fetch("run")).to include('matches_branch = candidate["head_branch"] == head_ref')
    expect(resolve_step.fetch("run")).to include('matches_branch && created_at >= (pr_updated_at - recent_window_seconds)')
  end

  it "matches current workflow runs using immutable run head metadata plus branch and recency for the current PR update" do
    expect(resolve_step.fetch("run")).to include('Array(candidate["pull_requests"]).find { |pr| pr["number"] == pr_number }')
    expect(resolve_step.fetch("run")).to include('!!pull_request_match(candidate, pr_number)')
    expect(resolve_step.fetch("run")).to include('(matches_head && (matches_pull_request || matches_branch)) ||')
    expect(resolve_step.fetch("run")).to include('recent_pr_run?(candidate, head_ref, pr_updated_at, recent_window_seconds)')
    expect(resolve_step.fetch("run")).to include('run = first_matching_run(repo, headers, poll_search_pages) do |candidate|')
  end

  it "falls back to the latest completed branch run when GitHub omits PR metadata for older screenshot runs" do
    expect(resolve_step.fetch("run")).to include('fallback_run ||= first_matching_run(repo, headers, poll_search_pages) do |candidate|')
    expect(resolve_step.fetch("run")).to include('candidate["status"] == "completed" &&')
    expect(resolve_step.fetch("run")).to include('return false unless candidate["head_branch"] == head_ref')
    expect(resolve_step.fetch("run")).to include('pull_requests = Array(candidate["pull_requests"])')
    expect(resolve_step.fetch("run")).to include('pull_requests.empty? || matches_pull_request?(candidate, pr_number)')
    expect(resolve_step.fetch("run")).to include('fallback_run_match?(candidate, pr_number, head_ref)')
    expect(resolve_step.fetch("run")).to include("run ||= fallback_run")
  end

  it "searches older workflow run pages during polling and for fallback recovery when the current run is off the first page" do
    expect(resolve_step.fetch("run")).to include("def write_outputs(path:, run_id: \"\", artifact_present: false, comment_status:, error_message: nil)")
    expect(resolve_step.fetch("run")).to include('def first_matching_run(repo, headers, pages)')
    expect(resolve_step.fetch("run")).to include('def workflow_runs_url(repo, page: 1)')
    expect(resolve_step.fetch("run")).to include('page=#{page}')
    expect(resolve_step.fetch("run")).to include('1.upto(pages) do |page|')
    expect(resolve_step.fetch("run")).to include('first_matching_run(repo, headers, poll_search_pages)')
    expect(resolve_step.fetch("run")).to include('fallback_run ||= first_completed_fallback_run(repo, headers, pr_number, head_ref, fallback_search_pages)')
  end

  it "degrades unresolved or ambiguous capture runs to capture_failed instead of failing the publish job" do
    expect(resolve_step.fetch("run")).to include('comment_status: "capture_failed"')
    expect(resolve_step.fetch("run")).to include('warn "Timed out waiting for PR Screenshots capture workflow for #{head_sha}"')
    expect(resolve_step.fetch("run")).to include("exit 0")
    expect(resolve_step.fetch("run")).to include('file.puts("error_message=#{error_message}") if error_message')
    expect(resolve_step.fetch("run")).not_to include('raise "Timed out waiting for PR Screenshots capture workflow')
    expect(resolve_step.fetch("run")).not_to include('"Could not determine screenshot capture outcome for workflow run')
  end

  it "degrades unexpected resolver errors to capture_failed instead of failing the publish job" do
    expect(resolve_step.fetch("run")).to include("rescue StandardError => e")
    expect(resolve_step.fetch("run")).to include('error_message: "#{e.class}: #{e.message}"')
    expect(resolve_step.fetch("run")).to include('warn "Failed to resolve PR Screenshots capture workflow for #{head_sha}: #{e.class}: #{e.message}"')
    expect(resolve_step.fetch("run")).to include("exit 0")
  end

  it "treats missing capture jobs as skipped only when detect completed cleanly and otherwise falls back to the workflow conclusion" do
    expect(resolve_step.fetch("run")).to include('elsif detect_job && %w[success neutral skipped].include?(detect_job["conclusion"])')
    expect(resolve_step.fetch("run")).to include('elsif run["conclusion"]')
    expect(resolve_step.fetch("run")).to include('"failure"')
  end

  it "passes only comment status at the final publish step and normalizes the fallback key before publishing" do
    expect(publish_env).to include("SCREENSHOT_COMMENT_STATUS" => "${{ steps.resolve.outputs.comment_status }}")
    expect(publish_env).not_to have_key("RAILS_MASTER_KEY")
    expect(publish_step.fetch("run")).to include('export RAILS_TEST_KEY="${RAILS_TEST_KEY:-$RAILS_MASTER_KEY_FALLBACK}"')
    expect(publish_step.fetch("run")).to include("bin/rails screenshots:publish")
  end
end
