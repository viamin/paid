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

  # @spec FACET-CONFIDENCE-019
  it "renders authorized response forms with their preserved drafts" do
    question = create(:feature_intent_decision, feature_intent: feature_intent)
    inferred_decision = create(:feature_intent_decision, :inferred_decision, feature_intent: feature_intent)
    policy_double = instance_double(FeatureIntentPolicy, approve?: true)
    view.define_singleton_method(:policy) { |_| policy_double }
    session[:feature_decision_drafts] = {
      feature_intent.id.to_s => {
        question.id.to_s => "Use CSV exports only.",
        inferred_decision.id.to_s => "Correct the inferred direction."
      }
    }

    render partial: "dashboard/inbox_detail_feature_decision",
      locals: { entry: entry_for(feature_intent), scoped_project: nil, selected_kind: Inbox::Queue::FEATURE_DECISION_KIND }

    expect(rendered).to have_css("textarea[name='answer'][required][maxlength='500']", count: 2)
    expect(rendered).to include("Use CSV exports only.", "Correct the inferred direction.")

    document = Nokogiri::HTML.fragment(rendered)
    textarea_ids = document.css("textarea[name='answer']").map { |node| node["id"] }
    expect(textarea_ids).to eq([ dom_id(question, :answer), dom_id(inferred_decision, :answer) ])
    answer_labels = document.css(%(label[for^="answer_feature_intent_decision"]))
    expect(answer_labels.map { |node| node["for"] }).to match_array(textarea_ids)
  end

  # @spec CONFIDENCE-DELIVERY-016
  it "does not render Mark approved for confidence-driven work" do
    confidence_feature = create(:feature_intent, :confidence_driven, project: project)
    create(:feature_intent_decision, feature_intent: confidence_feature, kind: "question")

    document = Nokogiri::HTML.fragment(render_detail(confidence_feature.reload))

    expect(document.text).to include("Confidence-driven delivery")
    expect(document.text).to include("Human action required")
    expect(document.text).not_to include("Mark approved")
    expect(document.at_css('[data-testid="feature-decision-action-answer_or_clarify"]')).to be_present
  end
end
