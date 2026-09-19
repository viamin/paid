# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::SynthesizeReview do
  let(:project) { build(:project) }
  let(:changed_lines) do
    Reviews::Verification::ChangedLines.from_files([
      {
        filename: "app/services/foo.rb",
        status: "modified",
        additions: 2,
        deletions: 0,
        patch: "@@ -1,2 +1,3 @@\n line one\n line two\n+new line three"
      }
    ])
  end

  def candidate_double(id:, path: "app/services/foo.rb", line: 3, summary: "Missing nil guard #{id}")
    Reviews::Verification::Candidate.new(
      id: id, path: path, line: line, summary: summary,
      triggering_condition: "params[:id] absent", failure_scenario: "NoMethodError"
    )
  end

  def confirmed_finding(id:, members: [ id ], path: "app/services/foo.rb", line: 3,
    summary: "Missing nil guard", claim_key: "nil-guard")
    member_candidates = members.map do |member_id|
      {
        candidate: candidate_double(id: member_id, summary: summary),
        verdict: Reviews::Verification::Verdict.new(
          candidate_id: member_id, verdict: :confirmed,
          evidence: "Line #{line} calls strip on nil.", claim_key: claim_key
        )
      }
    end
    Reviews::Verification::ConfirmedFinding.new(
      id: id, anchor_path: path, anchor_line: line,
      claim_key: claim_key, members: member_candidates
    )
  end

  def llm_response(json)
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: json,
      input_tokens: 60,
      output_tokens: 30,
      model: "claude-sonnet-4-6"
    )
  end

  describe ".call" do
    let(:deduplicated_payload) do
      <<~JSON
        {
          "body": "One confirmed issue.",
          "comments": [
            {
              "path": "app/services/foo.rb",
              "line": 3,
              "body": "Guard against nil before calling strip.",
              "source_candidate_ids": [1, 2]
            }
          ]
        }
      JSON
    end

    # @spec REVIEW-VERIFY-005
    it "returns one validated comment per deduplicated confirmed finding" do
      finding = confirmed_finding(id: 1, members: [ 1, 2 ])
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(deduplicated_payload))

      draft = described_class.call(
        project: project, findings: [ finding ], changed_lines: changed_lines
      )

      expect(draft.comments.length).to eq(1)
      comment = draft.comments.first
      expect(comment[:path]).to eq("app/services/foo.rb")
      expect(comment[:line]).to eq(3)
      expect(comment[:side]).to eq("RIGHT")
      expect(comment[:source_candidate_ids]).to eq([ 1, 2 ])
      expect(draft.body).to eq("One confirmed issue.")
      expect(draft.unanchored_bullets).to be_empty
    end

    # @spec REVIEW-VERIFY-004
    it "drops a comment citing candidate ids outside the confirmed findings" do
      finding = confirmed_finding(id: 1)
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(<<~JSON))
        {
          "body": "Summary",
          "comments": [
            { "path": "app/services/foo.rb", "line": 3, "body": "legit",
              "source_candidate_ids": [1] },
            { "path": "app/services/foo.rb", "line": 3, "body": "invented",
              "source_candidate_ids": [9] }
          ]
        }
      JSON

      draft = described_class.call(
        project: project, findings: [ finding ], changed_lines: changed_lines
      )

      expect(draft.comments.map { |c| c[:body] }).to eq([ "legit" ])
    end

    # @spec REVIEW-VERIFY-008
    it "drops a comment with an invalid anchor and surfaces it as an unanchored bullet" do
      finding = confirmed_finding(id: 1)
      allow(AgentHarness).to receive(:send_message).and_return(llm_response(<<~JSON))
        {
          "body": "Summary",
          "comments": [
            { "path": "app/services/foo.rb", "line": 99, "body": "valid finding, bad anchor",
              "source_candidate_ids": [1] }
          ]
        }
      JSON

      draft = described_class.call(
        project: project, findings: [ finding ], changed_lines: changed_lines
      )

      expect(draft.comments).to be_empty
      expect(draft.unanchored_bullets.length).to eq(1)
      expect(draft.unanchored_bullets.first).to include("valid finding, bad anchor")
    end

    # @spec REVIEW-VERIFY-005
    it "caps comments at the number of confirmed findings" do
      findings = [
        confirmed_finding(id: 1, claim_key: "a"),
        confirmed_finding(id: 2, claim_key: "b")
      ]
      comments = [ 1, 2, 3 ].map do |i|
        { path: "app/services/foo.rb", line: 3, body: "comment #{i}", source_candidate_ids: [ i ] }
      end
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response({ body: "Summary", comments: comments }.to_json)
      )

      draft = described_class.call(
        project: project, findings: findings, changed_lines: changed_lines
      )

      expect(draft.comments.length).to eq(2)
    end

    # @spec REVIEW-VERIFY-008
    it "moves an unanchored confirmed finding into a mechanical body bullet" do
      finding = confirmed_finding(id: 1, line: nil)
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response({ body: "Summary", comments: [] }.to_json)
      )

      draft = described_class.call(
        project: project, findings: [ finding ], changed_lines: changed_lines
      )

      expect(draft.comments).to be_empty
      expect(draft.unanchored_bullets.length).to eq(1)
      expect(draft.unanchored_bullets.first).to include("app/services/foo.rb", "Missing nil guard")
    end

    # @spec REVIEW-VERIFY-009
    it "reports token usage through the on_usage callback" do
      allow(AgentHarness).to receive(:send_message).and_return(
        llm_response({ body: "Summary", comments: [] }.to_json)
      )
      usages = []
      on_usage = ->(usage) { usages << usage }

      described_class.call(
        project: project, findings: [], changed_lines: changed_lines, on_usage: on_usage
      )

      expect(usages).to eq([
        { tokens_input: 60, tokens_output: 30, llm_model: "claude-sonnet-4-6", operation: "verified_review.synthesize" }
      ])
    end

    it "raises when synthesis output is unparseable" do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response("nope"))

      expect {
        described_class.call(project: project, findings: [], changed_lines: changed_lines)
      }.to raise_error(described_class::InvalidOutputError)
    end
  end
end
