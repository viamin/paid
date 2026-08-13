# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Runner tier model assignments", type: :system do
  include Warden::Test::Helpers

  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account) }
  let!(:project) { create(:project, account: account, created_by: user) }
  let!(:issue) { create(:issue, project: project, body: "x" * 700) }
  let!(:runner) do
    create(
      :runner,
      user: user,
      runner_key: "cursor"
    )
  end

  before do
    create(:llm_model, model_id: "claude-haiku-4-5", display_name: "Claude Haiku 4.5", provider: "anthropic", tier: "low")
    LlmModel.find_or_create_by!(model_id: "claude-sonnet-4-5") do |model|
      model.display_name = "Claude Sonnet 4.5"
      model.provider = "anthropic"
      model.category = "coding"
      model.tier = "mid"
      model.active = true
    end
    create(:llm_model, model_id: "claude-opus-4-1", display_name: "Claude Opus 4.1", provider: "anthropic", tier: "high")
    Warden.test_mode!
    login_as(user, scope: :user)
    allow(Models::MetaAgentSelector).to receive(:call).and_return(nil)
  end

  after do
    Warden.test_reset!
  end

  it "uses the saved tier mapping when selecting a model for a new run" do
    visit edit_runner_path(runner)

    select "Claude Sonnet 4.5", from: "runner_tier_model_ids_mid"
    click_button "Update Runner"

    expect(page).to have_content("Runner updated successfully.")
    expect(runner.reload.tier_model_ids["mid"]).to eq("claude-sonnet-4-5")

    agent_run = nil
    selection = nil

    TenantContext.with(account) do
      agent_run = create(:agent_run, :cursor, project: project, issue: issue, runner: runner)
      selection = Models::Select.call(agent_run: agent_run)
    end

    expect(selection.llm_model.model_id).to eq("claude-sonnet-4-5")
    expect(selection.tier).to eq("mid")
  end
end
