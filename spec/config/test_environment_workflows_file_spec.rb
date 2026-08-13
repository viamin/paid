# frozen_string_literal: true

require "rails_helper"
require "psych"

class TestEnvironmentWorkflowsFile < Pathname
end

RSpec.describe TestEnvironmentWorkflowsFile, :no_db do
  let(:workflow_paths) do
    %w[
      .github/workflows/ci.yml
      .github/workflows/claude-code-review.yml
      .github/workflows/pr-screenshots.yml
      .github/workflows/pr-screenshots-publish.yml
      .github/workflows/system_tests.yml
      .github/workflows/test_prof.yml
      .github/workflows/ephemeral_tests.yml
    ]
  end

  def workflow_config(path)
    Psych.safe_load_file(Rails.root.join(path), aliases: true)
  end

  def test_env_blocks_for(path)
    workflow = workflow_config(path)

    workflow.fetch("jobs").flat_map do |_name, job|
      blocks = []
      blocks << job.fetch("env") if job["env"].is_a?(Hash) && job.dig("env", "RAILS_ENV") == "test"

      blocks.concat(
        Array(job["steps"]).filter_map do |step|
          next unless step["env"].is_a?(Hash) && step.dig("env", "RAILS_ENV") == "test"

          step.fetch("env")
        end
      )

      blocks
    end
  end

  def normalize_steps_for(path)
    workflow = workflow_config(path)

    workflow.fetch("jobs").flat_map do |_name, job|
      Array(job["steps"]).select { |step| step["name"] == "Normalize test master key" }
    end
  end

  def prepare_workspace_cache_steps_for(path)
    workflow = workflow_config(path)

    workflow.fetch("jobs").filter_map do |_name, job|
      next unless job["env"].is_a?(Hash) && job.dig("env", "RAILS_ENV") == "test"

      steps = Array(job["steps"])
      prepare_index = steps.index { |step| step["name"] == "Prepare workspace cache directories" }
      ruby_index = steps.index { |step| step["name"] == "Set up Ruby" }
      node_index = steps.index { |step| step["name"] == "Set up Node" }
      next if prepare_index.nil? || ruby_index.nil? || node_index.nil?

      {
        step: steps.fetch(prepare_index),
        prepare_index:,
        ruby_index:,
        node_index:
      }
    end
  end

  it "sets an explicit test secret key base anywhere Rails boots in test mode" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(include("SECRET_KEY_BASE" => "test-secret-key-base")),
        "expected #{path} test env blocks to set SECRET_KEY_BASE explicitly"
    end
  end

  it "pins a stable test database name anywhere Rails boots in test mode" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(include("PAID_TEST_DATABASE" => "paid_test")),
        "expected #{path} test env blocks to pin PAID_TEST_DATABASE explicitly"
    end
  end

  it "passes the test master key alias anywhere Rails boots in test mode" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(include("RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}")),
        "expected #{path} test env blocks to pass RAILS_TEST_KEY explicitly"
    end
  end

  it "does not export RAILS_MASTER_KEY directly anywhere Rails boots in test mode" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(satisfy { |env| !env.key?("RAILS_MASTER_KEY") }),
        "expected #{path} test env blocks to rely on RAILS_TEST_KEY aliasing instead of exporting RAILS_MASTER_KEY directly"
    end
  end

  it "normalizes missing test keys from RAILS_MASTER_KEY before Rails boots" do
    %w[
      .github/workflows/ci.yml
      .github/workflows/pr-screenshots.yml
      .github/workflows/pr-screenshots-publish.yml
      .github/workflows/system_tests.yml
      .github/workflows/test_prof.yml
      .github/workflows/ephemeral_tests.yml
    ].each do |path|
      expect(normalize_steps_for(path)).to all(include("if" => "env.RAILS_TEST_KEY == ''")),
        "expected #{path} to normalize an empty RAILS_TEST_KEY"
      expect(normalize_steps_for(path).map { |step| step.fetch("env") }).to all(
        include("RAILS_MASTER_KEY_FALLBACK" => "${{ secrets.RAILS_MASTER_KEY }}")
      ), "expected #{path} to source the fallback key from RAILS_MASTER_KEY"
      expect(normalize_steps_for(path).map { |step| step.fetch("run") }).to all(
        include('echo "RAILS_TEST_KEY=$RAILS_MASTER_KEY_FALLBACK" >> "$GITHUB_ENV"')
      ), "expected #{path} to export the fallback key into RAILS_TEST_KEY"
    end
  end

  it "creates workspace-backed temp and cache directories before Ruby and Node setup in test jobs" do
    %w[
      .github/workflows/ci.yml
      .github/workflows/pr-screenshots.yml
      .github/workflows/pr-screenshots-publish.yml
      .github/workflows/system_tests.yml
      .github/workflows/test_prof.yml
      .github/workflows/ephemeral_tests.yml
    ].each do |path|
      prepare_steps = prepare_workspace_cache_steps_for(path)

      expect(prepare_steps).not_to be_empty, "expected #{path} test jobs to prepare workspace cache directories"
      expect(prepare_steps.map { |item| item.fetch(:step).fetch("run") }).to all(
        eq('mkdir -p "$TMPDIR" "$YARN_CACHE_FOLDER" "$XDG_CACHE_HOME" "$npm_config_cache" "$PLAYWRIGHT_BROWSERS_PATH"')
      ), "expected #{path} to create workspace-backed temp, package, and browser cache directories explicitly"
      expect(prepare_steps).to all(satisfy do |item|
        item.fetch(:prepare_index) < item.fetch(:ruby_index) &&
          item.fetch(:prepare_index) < item.fetch(:node_index)
      end), "expected #{path} to prepare cache directories before Ruby and Node setup"
    end
  end

  it "pins npm and Playwright caches into the workspace for test-mode jobs" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(
        include(
          "npm_config_cache" => "${{ github.workspace }}/.cache/npm",
          "PLAYWRIGHT_BROWSERS_PATH" => "${{ github.workspace }}/.cache/ms-playwright"
        )
      ), "expected #{path} test env blocks to pin npm and Playwright caches into the workspace"
    end
  end
end
