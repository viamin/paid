# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-028
RSpec.describe "dashboard inbox detail actions", type: :view do
  let(:account) { TenantContext.with_system_access { create(:account) } }
  let(:owner) { TenantContext.with_system_access { create(:user, :owner, account:) } }
  let(:project) do
    TenantContext.with_system_access do
      create(:project, account:, created_by: owner, owner: "acme", repo: "alpha", active: true)
    end
  end
  let(:issue) { TenantContext.with_system_access { create(:issue, project:, github_number: 7) } }
  let(:entry) do
    Inbox::Queue::Entry.new(
      id: "plan_review:1", kind: Inbox::Queue::PLAN_REVIEW_KIND, project:, issue:,
      record: plan_review, waiting_since: nil, questions: [], tasks: [ { "title" => "Ship it", "description" => "Land it." } ],
      summary_text: nil, title_text: nil, action_url: nil, guidance: nil, closeout_status: nil
    )
  end
  let(:plan_review) do
    TenantContext.with_system_access do
      create(:decomposition_decision, project:, issue:, workflow_id: "planning-workflow-1",
        decision_key: "planning-workflow-1:plan_review:pending", decision_type: "planning_outcome",
        outcome: DecompositionDecision::PLAN_PENDING_REVIEW_OUTCOME)
    end
  end

  before do
    captured_owner = owner
    view.define_singleton_method(:current_user) { captured_owner }
    allow(view).to receive_messages(inbox_query_params: { project_id: project.id, kind: entry.kind, sort: nil },
      inbox_path: "/inbox", inbox_entry_path: "/inbox/entry", approve_plan_review_path: "/plan_reviews/1/approve",
      reject_plan_review_path: "/plan_reviews/1/reject", revise_plan_review_path: "/plan_reviews/1/revise")
  end

  it "renders a labelled sticky action area before the decision content" do
    render partial: "dashboard/inbox_detail", locals: { entry:, scoped_project: project, selected_kind: entry.kind }

    fragment = Nokogiri::HTML.fragment(rendered)
    action_area = fragment.at_css("[data-inbox-detail-actions-target='area']")

    expect(action_area["aria-label"]).to eq("Inbox item actions")
    expect(action_area["class"]).to include("sticky")
    expect(fragment.css("[data-inbox-detail-actions-target='source']").first).to be_present
    expect(fragment.css("*").index(action_area)).to be < fragment.css("*").index(fragment.at_css("h3", text: "Proposed Task Breakdown"))
  end
end
