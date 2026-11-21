# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe LayeredVerificationFinding do
  self.use_transactional_tests = false

  let(:finding) { create(:layered_verification_finding) }
  let(:check_result) { create(:layered_verification_check_result, obligation: finding.obligation, agent_run: finding.agent_run) }

  after { finding.project.account.destroy! }

  # @spec LAYERED-VERIFY-017
  it "retains one observation when two deliveries load the same finding before recording" do
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map { concurrent_delivery(ready:, release:) }

    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { release << true }
    threads.each do |thread|
      raise "Concurrent finding recording timed out" unless thread.join(10)

      thread.value
    end

    expect(finding.reload.observations.size).to eq(1)
    expect(finding.observations.sole).to include("agent_run_id" => finding.agent_run_id, "check_result_ids" => [ check_result.id ])
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  private

  def concurrent_delivery(ready:, release:)
    account = finding.project.account
    finding_id = finding.id
    result_id = check_result.id
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with(account) do
          loaded = described_class.find(finding_id)
          ready << true
          release.pop
          loaded.add_observation!(
            obligation: loaded.obligation, agent_run: loaded.agent_run,
            check_result_ids: [ result_id ], evidence: { observed_behavior: { "check_results" => [ result_id ] } }
          )
        end
      end
    end
  end
end
