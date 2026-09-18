# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::FindCandidates do
  let(:project) { build(:project) }
  let(:files) do
    [
      {
        filename: "app/services/foo.rb",
        status: "modified",
        additions: 3,
        deletions: 1,
        patch: "@@ -1,3 +1,4 @@\n context\n-removed\n+added\n+more"
      }
    ]
  end

  def llm_response(json)
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: json,
      input_tokens: 100,
      output_tokens: 50,
      model: "claude-sonnet-4-6"
    )
  end

  describe ".call" do
    # @spec REVIEW-VERIFY-002
    it "returns validated candidates with the four required evidence fields" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(<<~JSON))
        {
          "candidates": [
            {
              "path": "app/services/foo.rb",
              "line": 2,
              "summary": "Nil-safe navigation dropped",
              "triggering_condition": "When params[:foo] is absent",
              "failure_scenario": "NoMethodError on nil for every caller",
              "category": "correctness"
            }
          ]
        }
      JSON

      candidates = described_class.call(
        project: project, pr_number: 7, files: files,
        pr_title: "Fix foo", pr_body: "Fixes #1"
      )

      expect(candidates.length).to eq(1)
      candidate = candidates.first
      expect(candidate.id).to eq(1)
      expect(candidate.path).to eq("app/services/foo.rb")
      expect(candidate.line).to eq(2)
      expect(candidate.summary).to eq("Nil-safe navigation dropped")
      expect(candidate.triggering_condition).to eq("When params[:foo] is absent")
      expect(candidate.failure_scenario).to eq("NoMethodError on nil for every caller")
    end

    # @spec REVIEW-VERIFY-002
    it "sends the diff and untrusted-data instructions through AgentHarness" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response('{"candidates": []}'))

      described_class.call(
        project: project, pr_number: 7, files: files,
        pr_title: "Fix foo", pr_body: "Body text"
      )

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including(
          "app/services/foo.rb",
          "@@ -1,3 +1,4 @@",
          "untrusted data",
          "Fix foo"
        ),
        hash_including(provider: :claude, tools: :none)
      )
    end

    # @spec REVIEW-VERIFY-002
    it "drops candidates referencing unchanged paths or missing evidence fields" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(<<~JSON))
        {
          "candidates": [
            { "path": "app/services/foo.rb", "line": 2, "summary": "ok",
              "triggering_condition": "t", "failure_scenario": "f" },
            { "path": "app/other.rb", "line": 2, "summary": "unknown path",
              "triggering_condition": "t", "failure_scenario": "f" },
            { "path": "app/services/foo.rb", "line": 0, "summary": "bad line",
              "triggering_condition": "t", "failure_scenario": "f" },
            { "path": "app/services/foo.rb", "line": 2, "summary": "",
              "triggering_condition": "t", "failure_scenario": "f" },
            { "path": "app/services/foo.rb", "line": 2, "summary": "no trigger",
              "triggering_condition": "  ", "failure_scenario": "f" },
            { "path": "app/services/foo.rb", "line": 2, "summary": "no failure",
              "triggering_condition": "t", "failure_scenario": "" }
          ]
        }
      JSON

      candidates = described_class.call(project: project, pr_number: 7, files: files)

      expect(candidates.map(&:summary)).to eq([ "ok" ])
    end

    # @spec REVIEW-VERIFY-002
    it "caps the candidate set" do
      payload = Array.new(described_class::MAX_CANDIDATES + 5) do |i|
        { path: "app/services/foo.rb", line: 2, summary: "finding #{i}",
          triggering_condition: "t", failure_scenario: "f" }
      end
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response({ candidates: payload }.to_json)
      )

      candidates = described_class.call(project: project, pr_number: 7, files: files)

      expect(candidates.length).to eq(described_class::MAX_CANDIDATES)
    end

    # @spec REVIEW-VERIFY-002
    it "returns no candidates for a clean PR (empty list)" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response('{"candidates": []}'))

      expect(
        described_class.call(project: project, pr_number: 7, files: files)
      ).to be_empty
    end

    # @spec REVIEW-VERIFY-003
    it "raises when the LLM output is unparseable" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response("not json at all"))

      expect {
        described_class.call(project: project, pr_number: 7, files: files)
      }.to raise_error(described_class::InvalidOutputError)
    end

    it "raises when the harness response reports failure" do
      allow(AgentHarness).to receive(:send_message).and_return(
        instance_double(AgentHarness::Response, success?: false, output: "", error: "boom")
      )

      expect {
        described_class.call(project: project, pr_number: 7, files: files)
      }.to raise_error(described_class::Error, /boom/)
    end

    # @spec REVIEW-VERIFY-009
    it "reports token usage through the on_usage callback" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response('{"candidates": []}'))
      usages = []
      on_usage = ->(usage) { usages << usage }

      described_class.call(project: project, pr_number: 7, files: files, on_usage: on_usage)

      expect(usages).to eq([
        { tokens_input: 100, tokens_output: 50, llm_model: "claude-sonnet-4-6", operation: "verified_review.find" }
      ])
    end
  end
end
