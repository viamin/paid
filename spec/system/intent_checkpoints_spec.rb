# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Intent checkpoint decisions", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:owner) { create(:user, :owner) }
  let(:project) { create(:project, account: owner.account) }
  let(:feature) { create(:feature_intent, project:, status: "needs_decision") }
  let(:questions) { create_list(:feature_intent_decision, 2, feature_intent: feature) }
  let!(:checkpoint) do
    create(:project_delegation_intent_checkpoint, feature_intent: feature).tap { |record| record.questions = questions }
  end

  before do
    Warden.test_mode!
    login_as(owner, scope: :user)
  end

  after { Warden.test_reset! }

  # @spec PROJECT-DELEGATION-002
  it "shows grouped guidance and keyboard-accessible reference details at narrow and wide widths" do
    [ 320, 390, 1440 ].each do |width|
      page.current_window.resize_to(width, 1000)
      visit_checkpoint
      group = find("[data-testid='intent-checkpoint-#{checkpoint.id}']")
      expect(group).to have_text(checkpoint.recommendation)
      expect(group).to have_text("Broad rollout")
      expect(group).to have_text("Existing customers remain unchanged.")
      expect(group).to have_css("li", text: questions.first.prompt)
      open_reference_details(group)
      rect = group.evaluate_script("this.getBoundingClientRect().toJSON()")
      expect(rect.fetch("left")).to be >= 0
      expect(rect.fetch("right")).to be <= width
    end
  end

  # @spec PROJECT-DELEGATION-002
  it "uses the original human answer forms to settle the group without approving the feature" do
    visit_checkpoint
    questions.each do |question|
      within("form[action$='/decisions/#{question.id}/respond']") do
        find("textarea").set("Keep the narrow rollout.")
        click_button "Save response"
      end
      expect(page).not_to have_css("form[action$='/decisions/#{question.id}/respond']")
      expect(page).to have_text("Response saved.")
    end

    expect(checkpoint.reload).to be_settled
    expect(checkpoint.settlements.sole.answers.size).to eq(2)
    expect(feature.reload.status).to eq("needs_decision")
  end

  def visit_checkpoint
    visit inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature.id}")
    expect(page).to have_css("[data-testid='intent-checkpoint-#{checkpoint.id}']")
  end

  def open_reference_details(group)
    expect(group).not_to have_css("details[open]")
    group.find("summary").native.node.focus
    page.driver.browser.keyboard.type(" ")
    expect(group).to have_css("details[open]")
    expect(group).to have_text(checkpoint.proposed_design_revision)
  end
end
