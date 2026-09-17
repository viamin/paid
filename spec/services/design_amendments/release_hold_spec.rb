# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-009
RSpec.describe DesignAmendments::ReleaseHold do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:amendment) { create(:design_amendment, feature_intent: feature, project: project, status: "merged") }
  let(:held_issue) { create(:issue, :pull_request, project: project) }
  let(:pause) do
    create(:design_amendment_pause, design_amendment: amendment, issue: held_issue,
      reason_code: "uncertain", evidence: { "cited_claims" => [ "Claim A" ] })
  end
  let(:actor) { create(:user, account: project.account) }

  before do
    Notifications::Publish.call(
      account: project.account,
      source: described_class::NOTIFICATION_SOURCE,
      subject: held_issue,
      severity: :error,
      title: "Design amendment impact is uncertain",
      blocking: true,
      metadata: { "cited_claims" => [ "Claim A" ] }
    )
  end

  it "releases the hold with actor and reason, and resolves the human notification" do
    released = described_class.call(pause: pause, actor: actor, reason: "Rechecked against the new baseline.")

    expect(released).to be_released
    expect(released.released_by).to eq(actor)
    expect(released.release_reason).to eq("Rechecked against the new baseline.")
    expect(DesignAmendmentPause.held_issue_ids(project)).not_to include(held_issue.id)
    notification = Notification.find_by(account: project.account, subject: held_issue)
    expect(notification.resolved_at).to be_present
  end

  it "refuses to release an already released hold" do
    pause.update!(status: "released", released_at: Time.current, released_by: actor)

    expect {
      described_class.call(pause: pause, actor: actor, reason: "Again.")
    }.to raise_error(DesignAmendments::InvalidTransitionError)
  end
end
