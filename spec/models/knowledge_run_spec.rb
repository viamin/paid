# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeRun do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:token_usages).dependent(:destroy) }
  end

  describe "validations" do
    subject(:knowledge_run) { build(:knowledge_run) }

    it { is_expected.to validate_inclusion_of(:operation_type).in_array(described_class::OPERATION_TYPES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_inclusion_of(:token_limit_status).in_array(described_class::TOKEN_LIMIT_STATUSES).allow_nil }
    it { is_expected.to validate_numericality_of(:total_tokens).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:max_tokens).only_integer.is_greater_than(0).allow_nil }
    it { is_expected.to validate_inclusion_of(:failure_reason).in_array(described_class::FAILURE_REASONS).allow_nil }
    it { is_expected.to validate_length_of(:error_class).is_at_most(150) }
  end

  describe "#active?" do
    it "returns true for pending runs" do
      expect(build(:knowledge_run, status: "pending")).to be_active
    end

    it "returns false for completed runs" do
      expect(build(:knowledge_run, status: "completed")).not_to be_active
    end
  end

  describe "#effective_max_tokens_per_run" do
    it "uses the explicit max_tokens when present" do
      expect(build(:knowledge_run, max_tokens: 1234).effective_max_tokens_per_run).to eq(1234)
    end

    it "falls back to the knowledge default" do
      expect(build(:knowledge_run, max_tokens: nil).effective_max_tokens_per_run).to eq(described_class::DEFAULT_MAX_TOKENS_PER_RUN)
    end
  end

  describe "#effective_provider" do
    it "prefers final_runner when present" do
      knowledge_run = build(:knowledge_run, final_provider: "openai", provider_attempts: [ { "provider" => "claude" } ])

      expect(knowledge_run.effective_provider).to eq("openai")
    end

    it "falls back to the last attempted provider" do
      knowledge_run = build(:knowledge_run, final_provider: nil, provider_attempts: [ { "provider" => "claude" }, { "provider" => "openai" } ])

      expect(knowledge_run.effective_provider).to eq("openai")
    end

    it "accepts runner-key attempts through the phase-one alias bridge", :no_db do
      knowledge_run = described_class.allocate
      knowledge_run.define_singleton_method(:final_runner) { nil }
      knowledge_run.define_singleton_method(:runner_attempts) { [ { "runner" => "claude" }, { "runner" => "openai" } ] }

      expect(knowledge_run.effective_provider).to eq("openai")
      expect(knowledge_run.effective_runner).to eq("openai")
    end
  end

  describe "runner alias bridge", :no_db do
    it "reads final_runner through the legacy final_provider column" do
      knowledge_run = described_class.allocate
      knowledge_run.define_singleton_method(:final_provider) { "openai" }

      expect(knowledge_run.final_runner).to eq("openai")
    end

    it "writes final_runner back to the legacy final_provider column" do
      knowledge_run = described_class.allocate
      stored_final_provider = nil
      knowledge_run.define_singleton_method(:final_provider=) { |value| stored_final_provider = value }

      knowledge_run.final_runner = "claude"

      expect(stored_final_provider).to eq("claude")
    end

    it "normalizes runner_attempts when reading the legacy provider_attempts column" do
      knowledge_run = described_class.allocate
      knowledge_run.define_singleton_method(:provider_attempts) { [ { "provider" => "claude" } ] }

      expect(knowledge_run.runner_attempts).to eq([ { "provider" => "claude", "runner" => "claude" } ])
    end

    it "stores runner_attempts back into the legacy provider_attempts column" do
      knowledge_run = described_class.allocate
      stored_attempts = nil
      knowledge_run.define_singleton_method(:provider_attempts=) { |value| stored_attempts = value }

      knowledge_run.runner_attempts = [ { "runner" => "openai", "attempted_at" => "2026-05-15T07:00:00Z" } ]

      expect(stored_attempts).to eq([ { "provider" => "openai", "attempted_at" => "2026-05-15T07:00:00Z" } ])
    end

    it "records runner attempts through the legacy writer" do
      knowledge_run = described_class.allocate
      stored_attempts = []
      knowledge_run.define_singleton_method(:provider_attempts) { stored_attempts }
      knowledge_run.define_singleton_method(:provider_attempts=) { |value| stored_attempts = value }

      knowledge_run.define_singleton_method(:update!) do |attrs|
        stored_attempts = attrs.fetch(:provider_attempts)
      end

      knowledge_run.record_runner_attempt("claude")

      expect(stored_attempts.last).to include("provider" => "claude")
      expect(knowledge_run.runner_attempts.last).to include("provider" => "claude", "runner" => "claude")
    end
  end

  describe "#ensure_proxy_token!" do
    it "returns the existing token when present" do
      knowledge_run = create(:knowledge_run)

      expect(knowledge_run.ensure_proxy_token!).to eq(knowledge_run.proxy_token)
    end

    it "generates and persists a token when proxy_token is nil" do
      knowledge_run = create(:knowledge_run)
      knowledge_run.update_column(:proxy_token, nil)

      token = knowledge_run.ensure_proxy_token!

      expect(token).to be_present
      expect(knowledge_run.reload.proxy_token).to eq(token)
    end
  end

  describe "completion helpers" do
    it "marks active runs as completed" do
      knowledge_run = create(:knowledge_run, :running)

      knowledge_run.complete!

      expect(knowledge_run.reload.status).to eq("completed")
      expect(knowledge_run.reload.completed_at).to be_present
    end

    it "marks active runs as failed" do
      knowledge_run = create(:knowledge_run, :running)

      knowledge_run.fail!

      expect(knowledge_run.reload.status).to eq("failed")
      expect(knowledge_run.reload.completed_at).to be_present
    end

    it "is a no-op on already-finished runs" do
      knowledge_run = create(:knowledge_run, :completed, completed_at: 2.minutes.ago)
      original_completed_at = knowledge_run.completed_at

      knowledge_run.complete!
      knowledge_run.fail!(reason: "containerized_providers_failed")

      expect(knowledge_run.reload.status).to eq("completed")
      expect(knowledge_run.completed_at).to be_within(1.second).of(original_completed_at)
      expect(knowledge_run.failure_reason).to be_nil
    end
  end

  # @spec KNOWLEDGE-011
  describe "failure diagnostics" do
    it "persists reason, error_class, and error_message on fail!" do
      knowledge_run = create(:knowledge_run, :running)

      knowledge_run.fail!(
        reason: "containerized_providers_failed",
        error_class: "AgentHarness::ProviderError",
        error_message: "proxy returned 502"
      )

      knowledge_run.reload
      expect(knowledge_run.status).to eq("failed")
      expect(knowledge_run.failure_reason).to eq("containerized_providers_failed")
      expect(knowledge_run.error_class).to eq("AgentHarness::ProviderError")
      expect(knowledge_run.error_message).to eq("proxy returned 502")
      expect(knowledge_run.completed_at).to be_present
    end

    it "accepts a structured attempt entry on record_provider_attempt" do
      knowledge_run = create(:knowledge_run, :running)

      knowledge_run.record_provider_attempt(
        "claude",
        outcome: "container_provider_error",
        error_class: "Knowledge::AnalysisRunner::ContainerError",
        error_message: "container exited 137"
      )

      entry = knowledge_run.reload.provider_attempts.last
      expect(entry).to include(
        "provider" => "claude",
        "outcome" => "container_provider_error",
        "error_class" => "Knowledge::AnalysisRunner::ContainerError",
        "error_message" => "container exited 137"
      )
      expect(entry["attempted_at"]).to match(/\A.+\z/)
    end

    it "annotates the most-recent attempt with mark_provider_attempt_outcome" do
      knowledge_run = create(:knowledge_run, :running)
      knowledge_run.record_provider_attempt("claude")
      knowledge_run.record_provider_attempt("openai")

      knowledge_run.mark_provider_attempt_outcome(
        provider: "openai",
        outcome: "provider_error",
        error_class: "AgentHarness::Error",
        error_message: "rate limit"
      )

      attempts = knowledge_run.reload.provider_attempts
      expect(attempts.first).to include("provider" => "claude")
      expect(attempts.first["outcome"]).to be_nil
      expect(attempts.last).to include(
        "provider" => "openai",
        "outcome" => "provider_error",
        "error_class" => "AgentHarness::Error",
        "error_message" => "rate limit"
      )
    end

    it "keeps the first recorded outcome when later annotations add error details" do
      knowledge_run = create(:knowledge_run, :running)
      knowledge_run.record_provider_attempt("claude")

      knowledge_run.mark_provider_attempt_outcome(
        provider: "claude",
        outcome: "unparseable_response"
      )
      knowledge_run.mark_provider_attempt_outcome(
        provider: "claude",
        outcome: "provider_error",
        error_class: "AgentHarness::ProviderError",
        error_message: "Runner claude returned unparseable response"
      )

      attempt = knowledge_run.reload.provider_attempts.last
      expect(attempt).to include(
        "provider" => "claude",
        "outcome" => "unparseable_response",
        "error_class" => "AgentHarness::ProviderError",
        "error_message" => "Runner claude returned unparseable response"
      )
    end

    it "is queryable by failure_reason so the dashboard can group failures" do
      create(:knowledge_run, :failed,
        project: create(:project),
        failure_reason: "containerized_providers_failed")
      create(:knowledge_run, :failed,
        project: create(:project),
        failure_reason: "in_process_providers_failed")
      create(:knowledge_run, :failed,
        project: create(:project),
        failure_reason: "containerized_providers_failed")

      reasons = described_class.where(status: "failed")
        .group(:failure_reason)
        .count

      expect(reasons).to eq(
        "containerized_providers_failed" => 2,
        "in_process_providers_failed" => 1
      )
    end

    it "rejects failure reasons outside FAILURE_REASONS" do
      knowledge_run = build(:knowledge_run, failure_reason: "totally_made_up")

      expect(knowledge_run).not_to be_valid
      expect(knowledge_run.errors[:failure_reason]).to be_present
    end
  end
end
