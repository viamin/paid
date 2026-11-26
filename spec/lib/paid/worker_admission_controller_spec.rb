# frozen_string_literal: true

require "rspec"
require "open3"
require_relative "../../../lib/paid/worker_admission"

RSpec.describe Paid::WorkerAdmission do # @spec TEMPORAL-ORCHESTRATION-021
  it "preserves reservation, generation, boot identity, abort and resume contracts" do
    root = File.expand_path("../../..", __dir__)
    output, status = Open3.capture2e(
      { "PYTHONPATH" => File.join(root, "bin/lib"), "PYTHONDONTWRITEBYTECODE" => "1" },
      "python3", File.join(root, "spec/support/worker_admission_controller_cases.py")
    )
    expect(output).to include("Ran 46 tests")
    expect(status.success?).to be(true), output
  end
end
