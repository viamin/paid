# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetrics::Record do
  let(:project) { create(:project) }

  describe ".call" do
    it "creates an LlmOutputMetric record" do
      expect {
        described_class.call(
          project: project,
          output_type: "pr_description",
          prompt_slug: "generation.pr_description",
          source_type: "PullRequest",
          source_id: 42
        )
      }.to change(LlmOutputMetric, :count).by(1)
    end

    it "sets the correct attributes" do
      metric = described_class.call(
        project: project,
        output_type: "pr_description",
        prompt_slug: "generation.pr_description",
        source_type: "PullRequest",
        source_id: 42,
        metadata: { "model" => "claude-sonnet-4-6" }
      )

      expect(metric).to have_attributes(
        project_id: project.id,
        account_id: project.account_id,
        output_type: "pr_description",
        prompt_slug: "generation.pr_description",
        source_type: "PullRequest",
        source_id: 42,
        scores: {},
        composite_score: nil
      )
      expect(metric.metadata).to include("model" => "claude-sonnet-4-6", "recorded_at" => be_present)
    end

    it "resolves the prompt version when a matching prompt exists" do
      prompt = create(:prompt, :with_version, slug: "generation.pr_description")

      metric = described_class.call(
        project: project,
        output_type: "pr_description",
        prompt_slug: "generation.pr_description",
        source_type: "PullRequest",
        source_id: 42
      )

      expect(metric.prompt_version).to eq(prompt.current_version)
    end

    it "returns nil on validation failure without raising" do
      result = described_class.call(
        project: project,
        output_type: "invalid_type",
        prompt_slug: "generation.pr_description",
        source_type: "PullRequest",
        source_id: 42
      )

      expect(result).to be_nil
    end

    it "returns the existing metric on duplicate source without creating a new one" do
      existing = described_class.call(
        project: project,
        output_type: "pr_description",
        prompt_slug: "generation.pr_description",
        source_type: "PullRequest",
        source_id: 42
      )

      expect {
        result = described_class.call(
          project: project,
          output_type: "pr_description",
          prompt_slug: "generation.pr_description",
          source_type: "PullRequest",
          source_id: 42
        )
        expect(result.id).to eq(existing.id)
      }.not_to change(LlmOutputMetric, :count)
    end
  end
end
