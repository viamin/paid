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

  it "sets an explicit test secret key base anywhere Rails boots in test mode" do
    workflow_paths.each do |path|
      expect(test_env_blocks_for(path)).to all(include("SECRET_KEY_BASE" => "test-secret-key-base")),
        "expected #{path} test env blocks to set SECRET_KEY_BASE explicitly"
    end
  end
end
