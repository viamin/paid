# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Temporal worker boot" do # rubocop:disable RSpec/DescribeClass
  # @spec TEMPORAL-ORCHESTRATION-023
  it "loads service constants before workflows can trigger Zeitwerk monitors" do
    worker = File.expand_path("../../../bin/temporal_worker", __dir__)
    source = <<~RUBY
      worker = #{worker.inspect}
      boot = File.read(worker).split("\nactivities =", 2).first
      eval(boot, TOPLEVEL_BINDING, worker)
      abort "PromptEvolution still autoloads" if Object.autoload?(:PromptEvolution)
      abort "CoordinationPolicyEvolution still autoloads" if Object.autoload?(:CoordinationPolicyEvolution)
      PromptEvolution::SampleRuns::QUALITY_THRESHOLD
      CoordinationPolicyEvolution::PrepareInputs::POLICY_TYPE
    RUBY
    _stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, RbConfig.ruby, "-e", source)

    expect(status.success?).to be(true), stderr
  end
end
