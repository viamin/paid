# frozen_string_literal: true

require "rails_helper"
require "psych"

class CiWorkflowFile < Pathname
end

RSpec.describe CiWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/ci.yml"),
      aliases: true
    )
  end

  it "passes the expected test credentials to the database-backed ci jobs" do
    jobs = workflow.fetch("jobs")

    expect(jobs.fetch("test").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}"
    )
    expect(jobs.fetch("performance").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base"
    )
  end
end
