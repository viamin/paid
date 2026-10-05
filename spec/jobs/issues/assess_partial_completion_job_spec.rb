# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::AssessPartialCompletionJob do
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, project: project, github_state: "open",
      partial_completion_at: 1.hour.ago,
      partial_completion_pr_number: 91,
      partial_completion_reason: "Earlier partial assessment.")
  end

  it "records the assessment verdict as the new partial-completion evidence when partial=true" do
    allow(Issues::PartialCompletionAssessment).to receive(:call).and_return(
      Issues::PartialCompletionAssessment::Result.new(partial: true, reason: "Still missing the migration step.")
    )

    described_class.perform_now(issue.id, 92)

    issue.reload
    expect(issue.partial_completion_at).to be_present
    expect(issue.partial_completion_pr_number).to eq(92)
    expect(issue.partial_completion_reason).to eq("Still missing the migration step.")
    expect(issue.paid_state).to eq("manual_review")
    expect(issue.manual_review_reason).to eq("Still missing the migration step.")
  end

  it "uses the parking time when a prerequisite resolves during the assessment" do # @spec AUTO-PICK-QUEUE-012
    parked_at = 2.hours.ago
    prerequisite = create(:issue, project: project)
    create(:issue_dependency, issue: issue, depends_on_issue: prerequisite)
    create(:issue, :pull_request, project: project, parent_issue: issue,
      github_state: "closed", pr_review_phase: "merged", github_number: 92)
    allow(Issues::PartialCompletionAssessment).to receive(:call) do
      prerequisite.update!(github_state: "closed", closed_at: 1.hour.ago)
      Issues::PartialCompletionAssessment::Result.new(partial: true, reason: "Still missing the migration step.")
    end

    described_class.perform_now(issue.id, 92, parked_at)

    expect(issue.reload.partial_completion_at).to be_within(0.000001).of(parked_at)
    expect(Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)).to include(issue)
  end

  it "clears the partial-completion columns when the assessment returns partial=false" do
    allow(Issues::PartialCompletionAssessment).to receive(:call).and_return(
      Issues::PartialCompletionAssessment::Result.new(partial: false, reason: "Resolved by the follow-up run.")
    )

    described_class.perform_now(issue.id, 92)

    issue.reload
    expect(issue.partial_completion_at).to be_nil
    expect(issue.partial_completion_pr_number).to be_nil
    expect(issue.partial_completion_reason).to be_nil
    # +paid_state+ is the activity's responsibility (parking); only the
    # partial-completion evidence is cleared here.
    expect(issue.paid_state).to eq("new")
  end

  it "leaves the partial-completion columns untouched when the assessment returns nil" do
    allow(Issues::PartialCompletionAssessment).to receive(:call).and_return(nil)

    described_class.perform_now(issue.id, 92)

    issue.reload
    expect(issue.partial_completion_at).to be_present
    expect(issue.partial_completion_pr_number).to eq(91)
    expect(issue.partial_completion_reason).to eq("Earlier partial assessment.")
  end

  it "no-ops when the issue has been deleted before the job runs" do
    allow(Issues::PartialCompletionAssessment).to receive(:call)

    expect {
      described_class.perform_now(Issue.maximum(:id).to_i + 1, 92)
    }.not_to raise_error

    expect(Issues::PartialCompletionAssessment).not_to have_received(:call)
  end

  it "no-ops when the issue is a pull request" do
    pull_request = create(:issue, :pull_request, project: project)
    allow(Issues::PartialCompletionAssessment).to receive(:call)

    described_class.perform_now(pull_request.id, 92)

    expect(Issues::PartialCompletionAssessment).not_to have_received(:call)
  end

  it "uses a generous perform_timeout so the LLM round trip cannot hang the worker" do
    expect(described_class.perform_timeout).to be > Issues::PartialCompletionAssessment::TIMEOUT
  end
end
