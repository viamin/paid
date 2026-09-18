# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-006
RSpec.describe Inbox::IntentConformance do
  let(:project) { create(:project, auto_merge_mode: "all") }

  def snapshot_hash(failed:, not_evaluated: [])
    { "failed" => failed, "not_evaluated" => not_evaluated }
  end

  def blocker(signal:, reason_code: "blocked")
    {
      "signal" => signal,
      "status" => "failed",
      "reason_code" => reason_code,
      "sanitized_message" => "#{signal} is blocking auto-merge",
      "next_action" => "Resolve #{reason_code}"
    }
  end

  def blocked_issue(**attrs)
    create(:issue, :pull_request, project: project, auto_merge_evaluated_at: Time.current,
      last_scanned_head_sha: "sha1",
      auto_merge_blockers: snapshot_hash(failed: [ blocker(signal: "intent_conformance_ok") ]),
      **attrs)
  end

  describe ".call" do
    it "returns nil when the PR is not open" do
      issue = blocked_issue(github_state: "closed")

      expect(described_class.call(issue)).to be_nil
    end

    it "returns nil when the blocker snapshot has no intent_conformance_ok failure" do
      issue = create(:issue, :pull_request, project: project, auto_merge_evaluated_at: Time.current,
        auto_merge_blockers: snapshot_hash(failed: [ blocker(signal: "owner_approved") ]))

      expect(described_class.call(issue)).to be_nil
    end

    it "returns nil when the PR is not in the ready phase" do
      issue = blocked_issue(pr_review_phase: "escalated")

      expect(described_class.call(issue)).to be_nil
    end

    it "returns nil when auto-merge is disabled on the project" do
      project.update!(auto_merge_mode: "off")
      issue = blocked_issue

      expect(described_class.call(issue)).to be_nil
    end

    it "returns nil when the project's merge permission was rejected" do
      issue = blocked_issue
      issue.update_columns(merge_permission_rejected_at: 1.minute.ago)

      expect(described_class.call(issue)).to be_nil
    end

    it "returns a snapshot when intent_conformance_ok has failed" do
      issue = blocked_issue
      verdict = create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1")

      snapshot = described_class.call(issue)

      expect(snapshot).not_to be_nil
      expect(snapshot.issue).to eq(issue)
      expect(snapshot.verdict).to eq(verdict)
      expect(snapshot.summary).to include("changes approved behavior")
    end

    it "describes an uncertain verdict distinctly from material drift" do
      issue = blocked_issue
      create(:intent_conformance_verdict, :uncertain, issue: issue, pr_head_sha: "sha1")

      expect(described_class.call(issue).summary).to include("Uncertain")
    end

    it "describes a missing verdict as not evaluated" do
      snapshot = described_class.call(blocked_issue)

      expect(snapshot.verdict).to be_nil
      expect(snapshot.summary).to include("could not evaluate")
    end

    it "surfaces the most recent human decision for the current head" do
      issue = blocked_issue
      create(:intent_conformance_verdict, :material_drift, issue: issue, pr_head_sha: "sha1")
      decision = create(:intent_conformance_decision, issue: issue, head_sha: "sha1")

      expect(described_class.call(issue).latest_decision).to eq(decision)
    end
  end
end
