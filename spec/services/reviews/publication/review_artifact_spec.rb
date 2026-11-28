# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Publication::ReviewArtifact do
  def review(body: "Summary", commit_id: "head-sha", id: 71)
    { "id" => id, "body" => body, "commit_id" => commit_id }
  end

  def comment(body: "Guard the missing path.", id: 81, review_id: 71)
    { "id" => id, "body" => body, "pull_request_review_id" => review_id }
  end

  # @spec REVIEW-PR-010
  it "rejects empty and whitespace inline finding bodies before publication" do
    [ "", " \n\t " ].each do |body|
      result = described_class.submission(body: "Summary", comments: [ { "body" => body } ])

      expect(result.status).to eq(:incomplete)
      expect(result.diagnostics).to include(submitted_comment_count: 1, submitted_body_lengths: [ body.length ])
    end
  end

  # @spec REVIEW-PR-010
  it "classifies a marker-only non-clean review as incomplete" do
    result = described_class.submission(
      body: "<!-- paid:code-review -->\n## Code Review\n\n",
      comments: []
    )

    expect(result.status).to eq(:incomplete)
  end

  # @spec REVIEW-PR-010
  it "recognizes an explicit clean outcome without inferring it from absent text" do
    payload = { body: "Generated no new comments. <!-- paid-review-clean -->", comments: [] }
    result = described_class.provider_result(
      submission: described_class.submission(**payload), review: review(body: payload[:body]),
      comments: [], current_head_sha: "head-sha"
    )

    expect(result.status).to eq(:clean)
  end

  # @spec REVIEW-PR-010
  it "preserves meaningful inline-only findings without requiring a summary" do
    submission = described_class.submission(body: "", comments: [ { "body" => "Guard the missing path." } ])
    result = described_class.provider_result(
      submission:, review: review(body: ""), comments: [ comment ], current_head_sha: "head-sha"
    )

    expect(result.status).to eq(:contentful_findings)
    expect(result.diagnostics).to include(review_id: 71, provider_comment_ids: [ 81 ])
  end

  # @spec REVIEW-PR-010
  it "does not accept a stale review commit as delivered" do
    submission = described_class.submission(body: "", comments: [ { "body" => "Guard the missing path." } ])
    result = described_class.provider_result(
      submission:, review: review(commit_id: "stale-sha"), comments: [ comment ], current_head_sha: "head-sha"
    )

    expect(result.status).to eq(:incomplete)
    expect(result.diagnostics).to include(head_matches_review: false)
  end

  # @spec REVIEW-PR-010
  it "classifies unexpectedly empty provider comments as incomplete" do
    submission = described_class.submission(body: "", comments: [ { "body" => "Guard the missing path." } ])
    result = described_class.provider_result(
      submission:, review: review(body: ""), comments: [ comment(body: "") ], current_head_sha: "head-sha"
    )

    expect(result.status).to eq(:incomplete)
    expect(result.diagnostics).to include(provider_body_lengths: [ 0 ])
  end

  # @spec REVIEW-PR-010
  it "does not mistake unavailable provider evidence for a clean review" do
    submission = described_class.submission(body: "", comments: [ { "body" => "Guard the missing path." } ])
    result = described_class.provider_result(
      submission:, review: review(body: ""), comments: nil, current_head_sha: nil
    )

    expect(result.status).to eq(:provider_evidence_unavailable)
  end
end
