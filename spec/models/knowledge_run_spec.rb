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
end
