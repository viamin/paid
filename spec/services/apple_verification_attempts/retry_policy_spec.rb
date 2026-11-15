# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::RetryPolicy do
  # @spec APPLE-ATTEMPT-010 APPLE-VERIFY-006 AGENT-RETRY-015 AGENT-RETRY-016
  let(:policy) { described_class.new }

  describe "#assess" do
    it "accepts an infrastructure failure below the retry limit" do
      attempt = create(:apple_verification_attempt, :failed,
        failure_classification: "capacity_or_quota", retry_number: 0)

      expect(policy.assess(attempt)).to have_attributes(
        eligible?: true,
        reason: :retryable_infrastructure_failure,
        attempt_number: 1
      )
    end

    it "refuses an infrastructure failure at the retry limit" do
      attempt = create(:apple_verification_attempt, :failed,
        failure_classification: "capacity_or_quota",
        retry_number: AppleVerificationAttempts::Config.max_retries)

      expect(policy.assess(attempt)).to have_attributes(
        eligible?: false,
        reason: :retry_limit_reached,
        attempt_number: AppleVerificationAttempts::Config.max_retries + 1
      )
    end

    it "refuses a deterministic project failure" do
      attempt = create(:apple_verification_attempt, :failed, failure_classification: "test_assertion")

      expect(policy.assess(attempt)).to have_attributes(
        eligible?: false,
        reason: :deterministic_project_failure
      )
    end

    it "refuses an attempt with no failure classification" do
      attempt = create(:apple_verification_attempt, :failed, failure_classification: nil)

      expect(policy.assess(attempt)).to have_attributes(
        eligible?: false,
        reason: :unclassified_failure
      )
    end

    it "refuses an attempt that is still active" do
      attempt = create(:apple_verification_attempt, status: "queued")

      expect(policy.assess(attempt)).to have_attributes(
        eligible?: false,
        reason: :attempt_active
      )
    end

    it "refuses an otherwise-eligible source that already has a successor" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")
      create(:apple_verification_attempt, retry_of_attempt: source)

      expect(policy.assess(source.reload)).to have_attributes(
        eligible?: false,
        reason: :successor_already_claimed
      )
    end
  end

  describe "#admission_reason" do
    it "is nil when the queue and per-run limits allow another attempt" do
      attempt = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")

      expect(policy.admission_reason(attempt)).to be_nil
    end

    it "is :queue_full when the fair queue is at depth" do
      attempt = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")
      allow(AppleVerificationAttempts::Queue).to receive(:full?).and_return(true)

      expect(policy.admission_reason(attempt)).to eq(:queue_full)
    end

    it "is :run_attempt_limit_reached when the run hit its attempt cap" do
      project = create(:project)
      attempt = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure",
        project:, account: project.account, agent_run: create(:agent_run, project:))

      with_env("APPLE_VERIFICATION_MAXIMUM_ATTEMPTS_PER_RUN" => "0") do
        expect(policy.admission_reason(attempt)).to eq(:run_attempt_limit_reached)
      end
    end
  end

  describe "#build_successor!" do
    it "copies the immutable source identity onto the queued successor" do
      source = create(:apple_verification_attempt, :failed, :committed,
        failure_classification: "worker_infrastructure",
        requested_capture: "ios-app.initial-screen", retry_number: 1)

      successor = policy.build_successor!(source, 2)

      expect(successor).to have_attributes(
        status: "queued",
        retry_number: 2,
        retry_of_attempt: source,
        account: source.account,
        agent_run: source.agent_run,
        apple_verification_workflow_revision: source.apple_verification_workflow_revision,
        apple_worker_profile: source.apple_worker_profile,
        source_digest: source.source_digest,
        commit_sha: source.commit_sha,
        requested_capture: source.requested_capture,
        lifecycle_gate: source.lifecycle_gate
      )
    end
  end

  describe "#duplicate_claim_conflict?" do
    it "recognizes the one-successor-per-source constraint" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")
      create(:apple_verification_attempt, retry_of_attempt: source)

      error = record_not_unique_from do
        create(:apple_verification_attempt, retry_of_attempt: source)
      end

      expect(policy.duplicate_claim_conflict?(error)).to be(true)
      expect(policy.duplicate_claim_conflict_reason(error)).to eq(:successor_already_claimed)
    end

    it "recognizes the one-active-attempt-per-run constraint" do
      project = create(:project)
      agent_run = create(:agent_run, project:)
      create(:apple_verification_attempt, status: "queued", project:, account: project.account, agent_run:)

      error = record_not_unique_from do
        create(:apple_verification_attempt, status: "queued", project:, account: project.account, agent_run:)
      end

      expect(policy.duplicate_claim_conflict?(error)).to be(true)
      expect(policy.duplicate_claim_conflict_reason(error)).to eq(:active_attempt_per_run)
    end

    it "does not claim unrelated unique violations" do
      error = ActiveRecord::RecordNotUnique.new("unrelated")

      expect(policy.duplicate_claim_conflict?(error)).to be(false)
    end
  end

  describe "durable decision recording" do
    it "records the applied claim scoped to the source attempt" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "worker_infrastructure")
      successor = policy.build_successor!(source, 1)

      policy.record_claim!(source, successor: successor,
        decision_point: described_class::DECISION_POINT,
        signals: { attempt: 1, max_attempts: policy.maximum_attempts })

      decision = OrchestrationDecision.last
      expect(decision).to have_attributes(
        project: source.project,
        agent_run: source.agent_run,
        actor: described_class::DECISION_POINT,
        decision_type: described_class::DECISION_POINT
      )
      expect(decision.context["decision_status"]).to eq("applied")
      expect(decision.context["apple_verification_attempt_id"]).to eq(source.id)
      expect(decision.inputs).to include("attempt" => 1, "max_attempts" => AppleVerificationAttempts::Config.max_retries)
      expect(decision.outputs).to include("new_apple_verification_attempt_id" => successor.id, "reason" => "retry_claimed")
    end

    it "records the noop skip with its reason" do
      source = create(:apple_verification_attempt, :failed, failure_classification: "test_assertion")

      policy.record_skip!(source, reason: :deterministic_project_failure,
        decision_point: described_class::DECISION_POINT,
        signals: { attempt: 1, max_attempts: policy.maximum_attempts })

      decision = OrchestrationDecision.last
      expect(decision.context["decision_status"]).to eq("noop")
      expect(decision.context["apple_verification_attempt_id"]).to eq(source.id)
      expect(decision.outputs["reason"]).to eq("deterministic_project_failure")
    end
  end

  private

  def record_not_unique_from
    yield
    raise "expected a RecordNotUnique from the given block"
  rescue ActiveRecord::RecordNotUnique => error
    error
  end

  def with_env(overrides)
    previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
