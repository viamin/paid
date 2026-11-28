# frozen_string_literal: true

require "rails_helper"
require "psych"

class EphemeralTestsWorkflowFile < Pathname
end

RSpec.describe EphemeralTestsWorkflowFile, :no_db do
  # @spec EPHEMERAL-CI-001
  it "filters workflow events to ephemeral tests and its own configuration" do
    workflow = Psych.safe_load_file(Rails.root.join(".github/workflows/ephemeral_tests.yml"))
    expect(workflow.fetch(true).fetch("pull_request")).to include(
      "types" => %w[opened synchronize reopened],
      "paths" => [
        ".ephemeral-tests/**/*_spec.rb", ".ephemeral-tests/**/*_test.js",
        ".ephemeral-tests/**/*_test.ts", ".github/workflows/ephemeral_tests.yml"
      ]
    )
  end

  # @spec EPHEMERAL-CI-002
  it "binds result comments to the tested revision and workflow run" do
    workflow = Psych.safe_load_file(Rails.root.join(".github/workflows/ephemeral_tests.yml"))
    step = workflow.fetch("jobs").fetch("comment-results").fetch("steps").first
    expect(step.fetch("env")).to include(
      "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}",
      "RUN_URL" => "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
    )
    expect(step.fetch("run")).to include('Tested revision: \`$HEAD_SHA\`', '[Workflow run]($RUN_URL)')
  end

  def multiline_fallback_key_export?(run_script)
    [
      'echo "RAILS_TEST_KEY<<${delimiter}"',
      "printf '%s\\n' \"$RAILS_MASTER_KEY_FALLBACK\"",
      'echo "${delimiter}"',
      '} >> "$GITHUB_ENV"'
    ].all? { |fragment| run_script.include?(fragment) }
  end

  it "passes test credentials and tolerates runners without a Chromium binary" do
    workflow = Psych.safe_load_file(
      Rails.root.join(".github/workflows/ephemeral_tests.yml"),
      aliases: true
    )
    run_tests_job = workflow.fetch("jobs").fetch("run-tests")
    locate_step = run_tests_job.fetch("steps").find { |step| step["name"] == "Locate Chromium-family browser" }

    expect(run_tests_job.fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_TEST_DATABASE" => "paid_test"
    )
    expect(run_tests_job.fetch("env")).not_to have_key("RAILS_MASTER_KEY")
    expect(locate_step.fetch("run")).to include("command -v chromium || true")
    expect(locate_step.fetch("run")).to include("falling back to rack_test")
  end

  it "normalizes a missing test key before running Rails commands" do
    workflow = Psych.safe_load_file(
      Rails.root.join(".github/workflows/ephemeral_tests.yml"),
      aliases: true
    )
    normalize_step = workflow.fetch("jobs").fetch("run-tests").fetch("steps").find do |step|
      step["name"] == "Normalize test master key"
    end

    expect(normalize_step).to include("if" => "env.RAILS_TEST_KEY == ''")
    expect(normalize_step.fetch("env")).to include("RAILS_MASTER_KEY_FALLBACK" => "${{ secrets.RAILS_MASTER_KEY }}")
    expect(multiline_fallback_key_export?(normalize_step.fetch("run"))).to be(true)
  end
end
