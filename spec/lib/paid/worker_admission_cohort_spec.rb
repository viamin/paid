# frozen_string_literal: true

require "rspec"
require "open3"
require_relative "../../../lib/paid/worker_admission"

RSpec.describe Paid::WorkerAdmission do # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
  it "resolves both actual worker roles from the supervisor process cohort" do
    root = File.expand_path("../../..", __dir__)
    output, status = Open3.capture2e(
      { "PYTHONPATH" => File.join(root, "bin/lib"), "PYTHONDONTWRITEBYTECODE" => "1" },
      "python3", File.join(root, "spec/support/worker_admission_cohort_cases.py")
    )
    expect(output).to include("Ran 8 tests")
    expect(status.success?).to be(true), output
  end
end
