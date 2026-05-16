# frozen_string_literal: true

require "rails_helper"
require "psych"

class TestEnvironmentWorkflowsFile < Pathname
end

RSpec.describe TestEnvironmentWorkflowsFile, :no_db do
  let(:workflow_paths) do
    %w[
      .github/workflows/ci.yml
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
end
