# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe AppleVerificationAttempts::Rerun do
  self.use_transactional_tests = false

  # @spec APPLE-ATTEMPT-010 AGENT-RETRY-006 AGENT-RETRY-018
  it "creates at most one successor when concurrent reruns claim the same attempt" do
    attempt = create(:apple_verification_attempt, status: "failed", failure_classification: "worker_infrastructure")

    reruns = concurrently_rerun(attempt)

    expect(reruns.map(&:id).uniq).to contain_exactly(reruns.first.id)
    expect(AppleVerificationAttempt.where(retry_of_attempt: attempt).count).to eq(1)
  ensure
    attempt&.account&.destroy!
  end

  private

  def concurrently_rerun(attempt)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          TenantContext.with(attempt.account) do
            ready << true
            start.pop
            described_class.call(attempt: AppleVerificationAttempt.find(attempt.id))
          end
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start << true }
    threads.map do |thread|
      raise "Concurrent Apple verification retry timed out" unless thread.join(10)

      thread.value
    end
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
