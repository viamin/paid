# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoPick do
  subject(:strategy) { described_class.new(candidate_source: candidate_source) }

  let(:project) { build_stubbed(:project, auto_pick_enabled: true) }
  let(:candidate_source) do
    class_double(Automation::Strategies::AutoPick::DefaultCandidateSource)
  end

  def build_context(metadata: {})
    Automation::Context.build(record: nil, project: project, metadata: metadata)
  end

  describe "#evaluate" do
    it "returns a queue_create_pr_run decision when a candidate is available" do
      issue = instance_double(Issue, id: 42)
      allow(candidate_source).to receive(:next_candidate).with(project).and_return(issue)

      result = strategy.evaluate(build_context)

      expect(result).to be_a(Automation::Result)
      expect(result.decisions.size).to eq(1)
      expect(result.decisions.first.type).to eq("queue_create_pr_run")
      expect(result.decisions.first.payload[:issue_id]).to eq(42)
    end

    it "returns a queue_analyze_issue_run decision when auto_enhance_enabled is true" do
      project = build_stubbed(:project, auto_pick_enabled: true, auto_enhance_enabled: true)
      issue = instance_double(Issue, id: 42)
      allow(candidate_source).to receive(:next_candidate).with(project).and_return(issue)

      result = strategy.evaluate(build_context_for(project))

      expect(result.decisions.size).to eq(1)
      expect(result.decisions.first.type).to eq("queue_analyze_issue_run")
      expect(result.decisions.first.payload[:issue_id]).to eq(42)
    end

    it "returns a noop result when auto-pick is disabled on the project" do
      project = build_stubbed(:project, auto_pick_enabled: false)
      allow(candidate_source).to receive(:next_candidate)

      result = strategy.evaluate(build_context_for(project))

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
      expect(candidate_source).not_to have_received(:next_candidate)
    end

    it "returns a noop result when quality is paused on the project" do
      allow(project).to receive(:quality_paused?).and_return(true)
      allow(candidate_source).to receive(:next_candidate)

      result = strategy.evaluate(build_context)

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
      expect(candidate_source).not_to have_received(:next_candidate)
    end

    it "returns a noop result when the candidate source has no issue to pick" do
      allow(candidate_source).to receive(:next_candidate).with(project).and_return(nil)

      result = strategy.evaluate(build_context)

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
    end

    it "defers when the PR-attention count meets the configured limit" do
      allow(candidate_source).to receive(:next_candidate)

      context = build_context(metadata: { pr_attention_count: 2, pr_attention_limit: 2 })
      result = strategy.evaluate(context)

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
      expect(candidate_source).not_to have_received(:next_candidate)
    end

    it "defers when the PR-attention count exceeds the configured limit" do
      allow(candidate_source).to receive(:next_candidate)

      context = build_context(metadata: { pr_attention_count: 5, pr_attention_limit: 1 })
      result = strategy.evaluate(context)

      expect(result.decisions.map(&:type)).to eq([ "noop" ])
      expect(candidate_source).not_to have_received(:next_candidate)
    end

    it "treats a zero limit as 'no limit' and still picks candidates" do
      issue = instance_double(Issue, id: 7)
      allow(candidate_source).to receive(:next_candidate).with(project).and_return(issue)

      context = build_context(metadata: { pr_attention_count: 100, pr_attention_limit: 0 })
      result = strategy.evaluate(context)

      expect(result.decisions.first.type).to eq("queue_create_pr_run")
      expect(result.decisions.first.payload[:issue_id]).to eq(7)
    end

    it "picks when the PR-attention count is below the configured limit" do
      issue = instance_double(Issue, id: 11)
      allow(candidate_source).to receive(:next_candidate).with(project).and_return(issue)

      context = build_context(metadata: { pr_attention_count: 1, pr_attention_limit: 3 })
      result = strategy.evaluate(context)

      expect(result.decisions.first.payload[:issue_id]).to eq(11)
    end

    it "defaults the candidate source to the provider-backed DefaultCandidateSource" do
      fallback_strategy = described_class.new

      expect(fallback_strategy.send(:instance_variable_get, :@candidate_source))
        .to eq(Automation::Strategies::AutoPick::DefaultCandidateSource)
    end
  end

  def build_context_for(p)
    Automation::Context.build(record: nil, project: p, metadata: {})
  end
end
