# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-005 @spec INTENT-AMENDMENT-006
# @spec INTENT-AMENDMENT-007 @spec INTENT-AMENDMENT-008
RSpec.describe DesignAmendments::EvaluateImpact do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:amendment) do
    create(:design_amendment, feature_intent: feature, project: project,
      status: "merged", amended_revision: "newrev", merged_at: Time.current,
      drift_evidence: { "changed_claims" => [ "Claim A: verdicts bind to PR head" ] })
  end
  let(:account) { project.account }

  def mapping_for(branches)
    branches.to_h { |issue, impact| [ issue.id, { impact: impact, cited_claims: [ "Claim A: verdicts bind to PR head" ], explanation: "Why #{impact}." } ] }
  end

  def stub_review(mapping)
    review = DesignAmendments::ImpactReview::Result.new(mapping: mapping, confidence: 0.9)
    allow(DesignAmendments::ImpactReview).to receive(:call).and_return(review)
  end

  def link_feature_issue(issue)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
  end

  def confidence_delivery_setup
    feature = create(:feature_intent, :confidence_driven, project: project)
    amendment = create(:design_amendment, feature_intent: feature, project: project,
      status: "merged", amended_revision: "newrev", merged_at: Time.current,
      drift_evidence: { "changed_claims" => [ "Claim A: verdicts bind to PR head" ] })
    completion_issue = create(:issue, project: project, github_number: 700, body: "Completion")
    affected_issue = create(:issue, project: project, github_number: 701, body: "Implementation")
    [ completion_issue, affected_issue ].each { |issue| create(:feature_intent_issue, feature_intent: feature, issue: issue) }
    FeatureIntentCompletion.create!(feature_intent: feature, completion_issue: completion_issue)
    [ amendment, completion_issue, affected_issue ]
  end

  def stub_confidence_client(completion_issue, *affected_issues)
    client = instance_double(GithubClient)
    remote_bodies = ([ completion_issue ] + affected_issues).to_h { |issue| [ issue.github_number, issue.body ] }
    remote_issue = Data.define(:body, :state)
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive(:issue) { |_repo, number| remote_issue.new(body: remote_bodies.fetch(number), state: "open") }
    allow(client).to receive(:update_issue) { |_repo, number, body: nil, **_options| remote_bodies[number] = body if body }
    remote_bodies
  end

  it "pauses affected branches and their dependency closure while independent work continues" do
    affected_pr = create(:issue, :pull_request, project: project)
    dependent = create(:issue, project: project, paid_state: "planning")
    independent = create(:issue, project: project, paid_state: "new")
    [ affected_pr, dependent, independent ].each { |issue| link_feature_issue(issue) }
    create(:issue_dependency, issue: dependent, depends_on_issue: affected_pr)
    stub_review(mapping_for({ affected_pr => "affected", dependent => "unaffected", independent => "unaffected" }))

    result = described_class.call(amendment: amendment)

    expect(result.paused).to eq(affected_pr.id => "affected", dependent.id => "dependent")
    expect(DesignAmendmentPause.where(issue: independent)).not_to exist
    expect(amendment.reload.impact.dig(affected_pr.id.to_s, "action")).to eq("paused")
    expect(amendment.evaluated_at).to be_present
  end

  it "holds uncertain branches and explains the uncertainty to a human" do
    uncertain_pr = create(:issue, :pull_request, project: project)
    link_feature_issue(uncertain_pr)
    stub_review(mapping_for({ uncertain_pr => "uncertain" }))

    described_class.call(amendment: amendment)

    pause = DesignAmendmentPause.find_by(issue: uncertain_pr)
    expect(pause.reason_code).to eq("uncertain")
    expect(pause).to be_held
    notification = Notification.active.find_by(account: account, subject: uncertain_pr)
    expect(notification).to be_blocking
    expect(notification.metadata["cited_claims"]).to eq([ "Claim A: verdicts bind to PR head" ])
    expect(notification.metadata["explanation"]).to eq("Why uncertain.")
  end

  it "fails closed when the review fails: every branch is held uncertain" do
    open_pr = create(:issue, :pull_request, project: project)
    unstarted = create(:issue, project: project, paid_state: "new")
    [ open_pr, unstarted ].each { |issue| link_feature_issue(issue) }
    allow(DesignAmendments::ImpactReview).to receive(:call).and_return(nil)

    result = described_class.call(amendment: amendment)

    expect(result.paused).to eq(open_pr.id => "uncertain", unstarted.id => "uncertain")
    expect(result.review_failed).to be(true)
    expect(DesignAmendmentPause.held.count).to eq(2)
  end

  it "records merged affected work as a follow-up decision instead of rolling it back" do
    merged_pr = create(:issue, :pull_request, project: project, github_state: "closed", pr_review_phase: "merged")
    link_feature_issue(merged_pr)
    stub_review(mapping_for({ merged_pr => "affected" }))
    before_paid_state = merged_pr.paid_state

    described_class.call(amendment: amendment)

    follow_up = DesignAmendmentFollowUp.find_by(issue: merged_pr)
    expect(follow_up).to be_open
    expect(follow_up.decision).to be_nil
    notification = Notification.active.find_by(account: account, subject: merged_pr)
    expect(notification).to be_blocking
    expect(notification.metadata["follow_up"]).to be(true)
    expect(DesignAmendmentPause.where(issue: merged_pr)).not_to exist
    merged_pr.reload
    expect(merged_pr.paid_state).to eq(before_paid_state)
    expect(merged_pr.pr_review_phase).to eq("merged")
  end

  it "records a follow-up for merged work when the review fails" do
    merged_pr = create(:issue, :pull_request, project: project, github_state: "closed", pr_review_phase: "merged")
    link_feature_issue(merged_pr)
    allow(DesignAmendments::ImpactReview).to receive(:call).and_return(nil)

    described_class.call(amendment: amendment)

    expect(DesignAmendmentFollowUp.open.find_by(issue: merged_pr)).to be_present
  end

  it "leaves unaffected merged work without a follow-up" do
    merged_pr = create(:issue, :pull_request, project: project, github_state: "closed", pr_review_phase: "merged")
    link_feature_issue(merged_pr)
    stub_review(mapping_for({ merged_pr => "unaffected" }))

    described_class.call(amendment: amendment)

    expect(DesignAmendmentFollowUp.where(issue: merged_pr)).not_to exist
  end

  it "pauses dependents outside the feature tree through dependency closure" do
    affected_pr = create(:issue, :pull_request, project: project)
    link_feature_issue(affected_pr)
    outsider_dependent = create(:issue, project: project, paid_state: "new")
    create(:issue_dependency, issue: outsider_dependent, depends_on_issue: affected_pr)
    stub_review(mapping_for({ affected_pr => "affected" }))

    result = described_class.call(amendment: amendment)

    expect(result.paused).to eq(affected_pr.id => "affected", outsider_dependent.id => "dependent")
    pause = DesignAmendmentPause.find_by(issue: outsider_dependent)
    expect(pause.reason_code).to eq("dependent")
    expect(pause.evidence["explanation"]).to include("Depends on a branch paused")
  end

  it "skips the reviewer and records an empty impact when the feature has no branches" do
    allow(DesignAmendments::ImpactReview).to receive(:call)

    result = described_class.call(amendment: amendment)

    expect(result.paused).to eq({})
    expect(result.follow_ups).to eq([])
    expect(result.review_failed).to be(false)
    expect(DesignAmendments::ImpactReview).not_to have_received(:call)
  end

  it "includes an open issue regardless of its internal Paid state" do # @spec AUTO-PICK-QUEUE-008
    in_progress = create(:issue, project: project, paid_state: "in_progress")
    link_feature_issue(in_progress)
    stub_review(mapping_for({ in_progress => "affected" }))

    result = described_class.call(amendment: amendment)

    expect(result.paused).to eq(in_progress.id => "affected")
    expect(DesignAmendmentPause.where(issue: in_progress)).to exist
  end

  it "routes confidence-driven assessment findings into completion-blocking forward work" do # @spec CONFIDENCE-DELIVERY-007 @spec CONFIDENCE-DELIVERY-008
    confidence_amendment, completion_issue, affected_issue = confidence_delivery_setup
    remote_bodies = stub_confidence_client(completion_issue, affected_issue)
    stub_review(mapping_for({ affected_issue => "affected" }))

    result = described_class.call(amendment: confidence_amendment)

    expect(result.paused).to eq({})
    expect(result.follow_ups).to eq([ affected_issue.id ])
    expect(FeatureIntentForwardWorkItem.find_by!(affected_issue: affected_issue).status).to eq("applied")
    expect(remote_bodies.fetch(700)).to include("Depends on #701")
    expect(DesignAmendmentPause.where(issue: affected_issue)).not_to exist
  end

  it "raises for retry without creating remote forward work when confidence assessment fails" do # @spec CONFIDENCE-DELIVERY-008
    confidence_amendment, completion_issue, affected_issue = confidence_delivery_setup
    client = instance_double(GithubClient)
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive(:create_issue)
    allow(client).to receive(:update_issue)
    allow(DesignAmendments::ImpactReview).to receive(:call).and_return(nil)

    expect {
      described_class.call(amendment: confidence_amendment)
    }.to raise_error(DesignAmendments::ImpactReviewFailedError)

    expect(FeatureIntentForwardWorkItem).not_to exist
    expect(client).not_to have_received(:create_issue)
    expect(client).not_to have_received(:update_issue)
    expect(completion_issue.reload.body).to eq("Completion")
    expect(affected_issue.reload.body).to eq("Implementation")
  end

  it "reconciles all confidence findings once after routing them" do # @spec CONFIDENCE-DELIVERY-008
    confidence_amendment, completion_issue, affected_issue = confidence_delivery_setup
    second_issue = create(:issue, project:, github_number: 702, body: "Second implementation")
    create(:feature_intent_issue, feature_intent: confidence_amendment.feature_intent, issue: second_issue)
    stub_confidence_client(completion_issue, affected_issue, second_issue)
    stub_review(mapping_for({ affected_issue => "affected", second_issue => "uncertain" }))

    described_class.call(amendment: confidence_amendment)

    client = project.client
    expect(client).to have_received(:issue).with(project.full_name, completion_issue.github_number).exactly(4).times
  end
end
