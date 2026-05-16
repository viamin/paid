# frozen_string_literal: true

require "rails_helper"
require "psych"

class SystemWorkflowFile < Pathname
end

RSpec.describe SystemWorkflowFile, :no_db do
  it "passes test credentials and falls back when Chromium is absent" do
    workflow = Psych.safe_load_file(
      Rails.root.join(".github/workflows/system_tests.yml"),
      aliases: true
    )
    system_job = workflow.fetch("jobs").fetch("system")
    locate_step = system_job.fetch("steps").find { |step| step["name"] == "Locate Chromium-family browser" }

    expect(system_job.fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_TEST_DATABASE" => "paid_test"
    )
    expect(locate_step.fetch("run")).to include('command -v chromium)')
    expect(locate_step.fetch("run")).to include("falling back to rack_test")
  end
end
