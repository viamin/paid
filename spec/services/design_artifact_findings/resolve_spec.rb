# frozen_string_literal: true

require "rails_helper"

RSpec.describe DesignArtifactFindings::Resolve do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:finding) { create(:design_artifact_finding, account:, project:) }

  # @spec OPERATOR-INBOX-018
  it "records a revision-bound linked-work decision without claiming resolution" do
    issue = create(:issue, project:)

    described_class.call(finding:, user:, state: "assigned", reason: "This issue owns the document repair.",
      revision: finding.revision, issue:)

    expect(finding.reload).to have_attributes(
      status: "assigned", resolution_state: "assigned", resolution_reason: "This issue owns the document repair.",
      resolution_actor: user, resolution_issue: issue
    )
  end

  # @spec OPERATOR-INBOX-018
  it "rejects a stale revision before changing queue visibility" do
    expect do
      described_class.call(finding:, user:, state: "dismissed", reason: "Historical record.", revision: "different")
    end.to raise_error(ArgumentError, "finding changed; reload before deciding")

    expect(finding.reload.status).to eq("open")
  end
end
