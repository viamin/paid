# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::WorkflowProjection do
  let(:project) { create(:project, auto_merge_mode: "off") }

  def blocker(signal, message)
    { "failed" => [ { "signal" => signal, "sanitized_message" => message, "next_action" => message } ], "not_evaluated" => [] }
  end

  it "keeps owner approval and manual merge as separate milestones" do
    # @spec OPERATOR-INBOX-023
    pull_request = create(:issue, :pull_request, project:, auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: blocker("owner_approved", "Ask the owner to approve."))

    projection = described_class.call(issue: pull_request)

    expect(projection.current.fetch(:key)).to eq("owner_approval")
    expect(projection.milestones).to include(a_hash_including(key: "merge", state: "waiting"))

    pull_request.update!(auto_merge_blockers: blocker("unrelated", "No remaining review gates."))

    expect(described_class.call(issue: pull_request).current).to include(key: "merge", state: "current", next_action: "Merge this pull request on GitHub.")
  end

  it "marks strict TDD test review as current until it is approved" do
    # @spec OPERATOR-INBOX-023
    pull_request = create(:issue, :pull_request, project:, pr_review_phase: "draft", labels: [ "paid-tests-ready-for-review" ])

    projection = described_class.call(issue: pull_request)

    expect(projection.current).to include(key: "test_review", state: "current")
    expect(projection.current.fetch(:next_action)).to include("Approve")
  end

  it "reports stale approval for a newer revision" do
    # @spec OPERATOR-INBOX-023
    pull_request = create(:issue, :pull_request, project:, auto_merge_evaluated_at: Time.current,
      last_scanned_head_sha: "new", auto_merge_blockers: blocker("reviews_fresh", "Approve the current revision."))

    projection = described_class.call(issue: pull_request)

    expect(projection.milestones).to include(a_hash_including(key: "owner_approval", state: "stale", revision: "new"))
  end
end
