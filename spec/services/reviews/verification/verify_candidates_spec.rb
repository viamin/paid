# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::VerifyCandidates do
  let(:project) { build(:project) }
  let(:head_sha) { "abc123abc123" }
  let(:candidates) do
    [
      Reviews::Verification::Candidate.new(
        id: 1,
        path: "app/services/foo.rb",
        line: 3,
        summary: "Missing nil guard",
        triggering_condition: "params[:id] absent",
        failure_scenario: "NoMethodError raised"
      )
    ]
  end
  let(:files) do
    [
      {
        filename: "app/services/foo.rb",
        status: "modified",
        additions: 2,
        deletions: 0,
        patch: "@@ -1,2 +1,3 @@\n line one\n line two\n+new line three"
      }
    ]
  end
  let(:content_loader) do
    ->(path) { path == "app/services/foo.rb" ? "line one\nline two\nnew line three\n" : nil }
  end

  def llm_response(json)
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: json,
      input_tokens: 80,
      output_tokens: 40,
      model: "claude-sonnet-4-6"
    )
  end

  def verdict_json(verdict:, claim_key:, evidence:, corrected: nil)
    payload = {
      "verdict" => verdict,
      "claim_key" => claim_key,
      "evidence" => evidence
    }
    payload["corrected_location"] = corrected if corrected
    payload.to_json
  end

  describe ".call" do
    # @spec REVIEW-VERIFY-003
    it "returns a verdict with evidence and a normalized claim key per candidate" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(verdict_json(
        verdict: "confirmed", claim_key: " Foo  NilGuard ", evidence: "Line 3 calls params[:id].strip without a guard."
      )))

      verdicts = described_class.call(
        project: project, head_sha: head_sha, candidates: candidates,
        files: files, content_loader: content_loader
      )

      expect(verdicts.length).to eq(1)
      verdict = verdicts.first
      expect(verdict.candidate_id).to eq(1)
      expect(verdict.verdict).to eq(:confirmed)
      expect(verdict.claim_key).to eq("foo-nilguard")
      expect(verdict.evidence).to include("Line 3")
    end

    # @spec REVIEW-VERIFY-003
    it "runs one independent model session per candidate and includes the code window" do
      two_candidates = candidates + [
        Reviews::Verification::Candidate.new(
          id: 2, path: "app/services/foo.rb", line: 1,
          summary: "Other", triggering_condition: "t", failure_scenario: "f"
        )
      ]
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response(verdict_json(verdict: "refuted", claim_key: "other", evidence: "No such behavior."))
      )

      described_class.call(
        project: project, head_sha: head_sha, candidates: two_candidates,
        files: files, content_loader: content_loader
      )

      expect(AgentHarness).to have_received(:send_message).twice
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Missing nil guard", "new line three"),
        hash_including(provider: :claude, tools: :none)
      )
    end

    # @spec REVIEW-VERIFY-003
    it "captures a corrected location from the verifier" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(verdict_json(
        verdict: "confirmed",
        claim_key: "nil-guard",
        evidence: "Trigger lives one line below the cited one.",
        corrected: { "path" => "app/services/foo.rb", "line" => 4 }
      )))

      verdicts = described_class.call(
        project: project, head_sha: head_sha, candidates: candidates,
        files: files, content_loader: content_loader
      )

      expect(verdicts.first.corrected_path).to eq("app/services/foo.rb")
      expect(verdicts.first.corrected_line).to eq(4)
    end

    # @spec REVIEW-VERIFY-003
    it "raises on an out-of-enum verdict instead of guessing" do
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response(verdict_json(verdict: "maybe", claim_key: "k", evidence: "e"))
      )

      expect {
        described_class.call(
          project: project, head_sha: head_sha, candidates: candidates,
          files: files, content_loader: content_loader
        )
      }.to raise_error(described_class::InvalidVerdictError)
    end

    # @spec REVIEW-VERIFY-003
    it "raises when the verifier output is unparseable" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response("garbage"))

      expect {
        described_class.call(
          project: project, head_sha: head_sha, candidates: candidates,
          files: files, content_loader: content_loader
        )
      }.to raise_error(described_class::InvalidOutputError)
    end

    # @spec REVIEW-VERIFY-003
    it "raises when the content loader cannot fetch the file (never becomes clean)" do
      allow(AgentHarness).to receive(:send_message)

      expect {
        described_class.call(
          project: project, head_sha: head_sha, candidates: candidates,
          files: files, content_loader: ->(_path) { nil }
        )
      }.to raise_error(described_class::Error, /content/)
    end

    # @spec REVIEW-VERIFY-009
    it "reports per-candidate token usage" do
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response(verdict_json(verdict: "plausible", claim_key: "k", evidence: "e"))
      )
      usages = []
      on_usage = ->(usage) { usages << usage }

      described_class.call(
        project: project, head_sha: head_sha, candidates: candidates,
        files: files, content_loader: content_loader, on_usage: on_usage
      )

      expect(usages).to eq([
        { tokens_input: 80, tokens_output: 40, llm_model: "claude-sonnet-4-6", operation: "verified_review.verify" }
      ])
    end
  end
end
