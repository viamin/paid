# frozen_string_literal: true

require "rails_helper"

# Concurrent monitor/rerun claims must produce at most one successor per
# terminal source attempt; the losing claim resolves to a skipped outcome
# with an inspectable reason instead of an error.
# @spec APPLE-ATTEMPT-010 APPLE-VERIFY-006 AGENT-RETRY-005 AGENT-RETRY-006 AGENT-RETRY-016
RSpec.describe AppleVerificationAttempts::RetryMonitor, ".call" do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:source) do
    create(:apple_verification_attempt, :failed, :committed,
      failure_classification: "worker_infrastructure", project:, account:)
  end

  after do
    AppleVerificationAttempt.where(project:).destroy_all
    OrchestrationDecision.where(project:).delete_all
    project.destroy!
    account.destroy!
  end

  it "creates exactly one successor when two claims race" do
    results = race(
      -> { claim_mechanics.claim(source_id: source.id) },
      -> { claim_mechanics.claim(source_id: source.id) }
    )

    expect(results.select(&:claimed?)).to have_attributes(count: 1)
    expect(results.select(&:skipped?).map(&:reason)).to contain_exactly(:successor_already_claimed)
    expect(AppleVerificationAttempt.where(retry_of_attempt: source.id)).to have_attributes(count: 1)

    decisions = OrchestrationDecision.where(project:)
    expect(decisions.map { |decision| decision.context["decision_status"] }).to contain_exactly("applied", "noop")
  end

  it "creates exactly one successor when the monitor and an operator rerun race" do
    outcomes = race(
      -> { described_class.call },
      -> { rerun_outcome }
    )

    monitor_result, rerun_outcome = outcomes
      .partition { |outcome| outcome.is_a?(AppleVerificationAttempts::RetryMonitor::Result) }
      .then { |monitor, rerun| [ monitor.first, rerun.first ] }

    expect(monitor_result.retried).to be <= 1
    expect(AppleVerificationAttempt.where(retry_of_attempt: source.id)).to have_attributes(count: 1)

    successor = AppleVerificationAttempt.find_by(retry_of_attempt: source.id)
    expect(rerun_outcome.last).to eq(successor) if rerun_outcome.first == :rerun
  end

  private

  def claim_mechanics
    Retries::Attempt.new(
      policy: AppleVerificationAttempts::RetryPolicy.new,
      decision_point: AppleVerificationAttempts::RetryPolicy::DECISION_POINT
    )
  end

  def rerun_outcome
    [ :rerun, AppleVerificationAttempts::Rerun.call(attempt: AppleVerificationAttempt.find(source.id)) ]
  rescue ArgumentError => error
    [ :rerun_error, error.message ]
  end

  def race(first_work, second_work)
    ready = Queue.new
    start = Queue.new
    outcomes = Queue.new
    threads = [ first_work, second_work ].map do |work|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes << work.call
        end
      end
    end

    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| raise "Concurrent retry claim timed out" unless thread.join(10) }

    2.times.map { outcomes.pop }
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
