# frozen_string_literal: true

require "rspec"
require "open3"
require_relative "../../../lib/paid/worker_admission"

RSpec.describe Paid::WorkerAdmission do # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
  it "retains the owned controller across replacement without inherited pipes" do
    root = File.expand_path("../../..", __dir__)
    output, status = Open3.capture2e(
      { "PYTHONDONTWRITEBYTECODE" => "1" },
      "python3", File.join(root, "spec/support/dev_worker_admission_cases.py")
    )
    expect(output).to include("Ran 7 tests")
    expect(status.success?).to be(true), output
  end
end
