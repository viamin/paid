# frozen_string_literal: true

require "rails_helper"
require "psych"

class SecurityWorkflowFile < Pathname
end

RSpec.describe SecurityWorkflowFile, :no_db do
  # @spec REPO-DEPENDENCY-AUDIT-009
  it "retries audit failures without allowing a persistent failure to pass" do
    workflow = Psych.safe_load_file(
      Rails.root.join(".github/workflows/security.yml"),
      aliases: true
    )
    audit_step = workflow.fetch("jobs").fetch("audit").fetch("steps").find do |step|
      step["name"] == "Run security audit and secret scan"
    end
    command = audit_step.fetch("run")

    expect(command).to include('for attempt in 1 2 3; do', "if bin/audit; then", 'exit 0')
    expect(command).to include('if [ "$attempt" -lt 3 ]; then', 'sleep "$((attempt * 10))"')
    expect(command).to end_with("exit 1\n")
  end
end
