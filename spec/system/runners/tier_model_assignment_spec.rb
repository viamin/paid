# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Runner tier model assignments", type: :system do
  include Warden::Test::Helpers

  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account) }
  let!(:project) { create(:project, account: account, created_by: user) }
  let!(:issue) { create(:issue, project: project, body: "x" * 700) }
  let!(:api_key) { create(:runner_api_key, user: user, api_service_type: "openrouter") }
  let!(:runner) do
    create(
      :runner,
      user: user,
      auth_type: "api_key",
      provider_api_key: api_key,
      runner_key: "opencode",
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
    )
  end

  before do
    create(:llm_model, model_id: "low-openrouter", display_name: "Low OpenRouter", provider: "openrouter", tier: "low")
    LlmModel.find_or_create_by!(model_id: "moonshotai/kimi-k2-0905") do |model|
      model.display_name = "Kimi K2"
      model.provider = "openrouter"
      model.category = "coding"
      model.tier = "mid"
      model.active = true
    end
    create(:llm_model, model_id: "high-openrouter", display_name: "High OpenRouter", provider: "openrouter", tier: "high")
    Warden.test_mode!
    login_as(user, scope: :user)
    allow(Models::MetaAgentSelector).to receive(:call).and_return(nil)
  end

  after do
    Warden.test_reset!
  end

  it "uses the saved tier mapping when selecting a model for a new run" do
    visit edit_runner_path(runner)

    select "Kimi K2", from: "runner_tier_models_mid"
    click_button "Update Runner"

    expect(page).to have_content("Runner updated successfully.")
    expect(runner.reload.tier_models.dig("mid", "model_id")).to eq("moonshotai/kimi-k2-0905")

    agent_run = create(:agent_run, project: project, issue: issue, runner: runner, agent_type: "opencode")

    selection = Models::Select.call(agent_run: agent_run)

    expect(selection.llm_model.model_id).to eq("moonshotai/kimi-k2-0905")
    expect(selection.tier).to eq("mid")
  end
end
