# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "timeout"

RSpec.describe "Native Temporal slot lifecycle" do # rubocop:disable RSpec/DescribeClass
  # @spec TEMPORAL-ORCHESTRATION-024
  it "completes heartbeat and GC contention, cancellation, and admission release" do
    script = File.expand_path("../../support/worker_admission_native.rb", __dir__)
    output = +""
    status = nil
    Open3.popen2e(RbConfig.ruby, script, pgroup: true) do |input, stream, waiter|
      input.close
      begin
        Timeout.timeout(120) do
          output << stream.read
          status = waiter.value
        end
      ensure
        if waiter.alive?
          Process.kill("KILL", -waiter.pid)
          waiter.join
        end
      end
    end

    expect(status.success?).to be(true), output
    expect(output).to include('"workflows_completed":32', '"cancellation":true', '"admission_released":true')
  end
end
