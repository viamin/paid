# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-023
RSpec.describe "dashboard/_inbox_detail_feature_decision", type: :view do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }

  def entry_for(feature_intent)
    Inbox::Queue::Entry.new(
      id: "feature_decision:#{feature_intent.id}",
      kind: Inbox::Queue::FEATURE_DECISION_KIND,
      project: feature_intent.project,
      issue: nil,
      record: feature_intent,
      waiting_since: feature_intent.created_at,
      questions: [],
      tasks: [],
      summary_text: "Awaiting approval.",
      title_text: feature_intent.title,
      action_url: nil
    )
  end

  def render_detail(feature_intent)
    policy_double = instance_double(FeatureIntentPolicy, approve?: false)
    view.define_singleton_method(:policy) { |_| policy_double }
    render partial: "dashboard/inbox_detail_feature_decision",
      locals: { entry: entry_for(feature_intent), scoped_project: nil, selected_kind: Inbox::Queue::FEATURE_DECISION_KIND }
    rendered
  end

  it "renders a hold badge for each linked issue in the proposed tree" do
    issue = create(:issue, project: project)
    create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)

    document = Nokogiri::HTML.fragment(render_detail(feature_intent.reload))

    expect(document.at_css(%(li [data-testid="feature-intent-hold"]))).to be_present
  end

  it "loads the tree's feature-intent links through preloads, not per-issue queries" do
    3.times do |i|
      issue = create(:issue, project: project, github_number: 100 + i)
      create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)
    end

    queries = capture_queries { render_detail(feature_intent.reload) }

    expect(queries.grep(/"feature_intent_issues"."issue_id" = /)).to be_empty
  end
end
