# frozen_string_literal: true

require "rails_helper"
require "psych"

class EphemeralCleanupWorkflowFile < Pathname
end

RSpec.describe EphemeralCleanupWorkflowFile, :no_db do
  # @spec EPHEMERAL-CLEANUP-001
  it "labels cleanup pull requests for Paid before requesting auto-merge" do
    workflow = Psych.safe_load_file(Rails.root.join(".github/workflows/ephemeral-cleanup.yml"), aliases: true)
    cleanup_job = workflow.fetch("jobs").fetch("cleanup")
    create_step = cleanup_job.fetch("steps").find { |step| step["name"] == "Open auto-merging cleanup PR" }
    script = create_step.fetch("run")

    expect(workflow.fetch("permissions")).to include("issues" => "write")
    expect(create_step.fetch("env")).to include("GH_TOKEN" => "${{ github.token }}")
    expect(script).to include("--label paid-automation", "--label paid-generated")
    expect(script.index("--label paid-automation")).to be < script.index("gh pr merge")
    expect(script.index("--label paid-generated")).to be < script.index("gh pr merge")
  end
end
