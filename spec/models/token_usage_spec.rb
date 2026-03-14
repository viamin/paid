# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenUsage do
  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    subject { build(:token_usage) }

    it { is_expected.to validate_presence_of(:request_type) }
    it { is_expected.to validate_inclusion_of(:request_type).in_array(described_class::REQUEST_TYPES) }
    it { is_expected.to validate_numericality_of(:input_tokens).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:output_tokens).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:cost_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_length_of(:llm_model).is_at_most(100) }
  end

  describe "#total_tokens" do
    it "returns sum of input and output tokens" do
      usage = build(:token_usage, input_tokens: 1000, output_tokens: 500)
      expect(usage.total_tokens).to eq(1500)
    end
  end

  describe "scopes" do
    describe ".by_project" do
      it "returns token usages for a specific project" do
        project = create(:project)
        agent_run = create(:agent_run, :running, project: project)
        usage = create(:token_usage, agent_run: agent_run)

        other_project = create(:project)
        other_run = create(:agent_run, :running, project: other_project)
        create(:token_usage, agent_run: other_run)

        expect(described_class.by_project(project.id)).to contain_exactly(usage)
      end
    end

    describe ".by_model" do
      it "filters by model name" do
        usage1 = create(:token_usage, llm_model: "claude-3-5-sonnet-20241022")
        create(:token_usage, llm_model: "gpt-4o")

        expect(described_class.by_model("claude-3-5-sonnet-20241022")).to contain_exactly(usage1)
      end
    end

    describe ".by_request_type" do
      it "filters by request type" do
        usage1 = create(:token_usage, request_type: "planning")
        create(:token_usage, request_type: "agent")

        expect(described_class.by_request_type("planning")).to contain_exactly(usage1)
      end
    end

    describe ".by_time_period" do
      it "filters by time range" do
        usage1 = create(:token_usage, created_at: 2.days.ago)
        create(:token_usage, created_at: 10.days.ago)

        expect(described_class.by_time_period(3.days.ago, Time.current)).to contain_exactly(usage1)
      end
    end
  end

  describe "aggregation methods" do
    before do
      create(:token_usage, input_tokens: 1000, output_tokens: 500, cost_cents: 10, llm_model: "claude-3-5-sonnet-20241022", request_type: "agent")
      create(:token_usage, input_tokens: 2000, output_tokens: 1000, cost_cents: 20, llm_model: "gpt-4o", request_type: "planning")
    end

    describe ".total_cost_cents" do
      it "returns total cost" do
        expect(described_class.total_cost_cents).to eq(30)
      end
    end

    describe ".cost_by_model" do
      it "groups costs by model" do
        result = described_class.cost_by_model
        expect(result["claude-3-5-sonnet-20241022"]).to eq(10)
        expect(result["gpt-4o"]).to eq(20)
      end
    end

    describe ".cost_by_request_type" do
      it "groups costs by request type" do
        result = described_class.cost_by_request_type
        expect(result["agent"]).to eq(10)
        expect(result["planning"]).to eq(20)
      end
    end
  end
end
