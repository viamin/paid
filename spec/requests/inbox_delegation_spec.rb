# frozen_string_literal: true

require "rails_helper"

# RDR-080 surface parity: the Inbox detail reads delegated authority from the
# shared ProjectDelegation::Projection, so operators see the same effective
# policy the runtime boundaries enforce.
#
# @spec PROJECT-DELEGATION-005
RSpec.describe "Inbox delegated authority" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) do
    create(:issue, :needs_input, project:, github_state: "open",
      needs_input_questions: [ "Which behavior?" ])
  end

  before do
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
    sign_in user
  end

  def authorize_review
    create(:bounded_delegated_action,
      project: project,
      issue: issue,
      action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: issue, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  def detail_body
    get inbox_entry_path(entry_id: "clarifying_questions:#{issue.id}")
    response.body
  end

  it "renders no delegated-authority block while the project gate is off" do # @spec PROJECT-DELEGATION-005
    authorize_review

    expect(detail_body).not_to include("Delegated authority")
  end

  it "renders the shared projection's authority on the entry detail" do # @spec PROJECT-DELEGATION-005
    FeatureFlags.enable!(:project_delegation, project:)
    authorize_review

    body = detail_body

    expect(body).to include("Delegated authority")
    expect(body).to include("legacy policy")
  end
end
