# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Runner ZDR model selection", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:api_key) { create(:provider_api_key, user:, api_service_type: "openrouter") }
  let!(:runner) do
    create(:runner, user:, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "anthropic/claude-sonnet-4" } })
  end

  before do
    setting = account.tenant_setting!
    setting.update!(features: setting.features.merge("runner_model_policy_form" => true))
    [ [ "anthropic/claude-sonnet-4", "anthropic", "Paid Sonnet" ],
      [ "google/gemini-2.5-flash:free", "google", "Free Gemini" ],
      [ "qwen/unverified", "qwen", "Unverified Qwen" ] ].each do |id, provider, label|
      model = LlmModel.find_or_initialize_by(model_id: id)
      model.update!(provider:, display_name: label, active: true,
        catalog_source: "openrouter_sync", tier: "mid",
        pricing_tier: id.end_with?(":free") ? "free" : "paid",
        input_cost_per_million: id.end_with?(":free") ? 0 : 3,
        output_cost_per_million: id.end_with?(":free") ? 0 : 15)
    end
    create(:openrouter_zdr_model, model_id: "anthropic/claude-sonnet-4")
    create(:openrouter_zdr_model, model_id: "google/gemini-2.5-flash:free")
    OpenrouterZdrCatalog.current.update!(last_successful_at: Time.current)
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  # @spec RUNNER-MODEL-OPTIONS-008 RUNNER-MODEL-OPTIONS-009 DIRECT-OUTBOUND-CATALOG-011
  it "filters concrete paid/free choices and saves an explicit keyboard selection at mobile width" do
    page.current_window.resize_to(390, 844)
    visit edit_runner_path(runner)
    check "Require zero data retention"
    expect(page).to have_css("#runner_model_selection_choice option[value='google/gemini-2.5-flash:free']", visible: :all)
    values = page.evaluate_script("Array.from(document.querySelector('#runner_model_selection_choice').options).map(o => o.value)")
    expect(values).to include("anthropic/claude-sonnet-4", "google/gemini-2.5-flash:free")
    expect(values).not_to include("free", "qwen/unverified", "__custom__")
    search = find("#runner_model_search")
    search.fill_in with: "Gemini"
    search.send_keys(:down, :enter)
    expect(find("#runner_model_selection_choice").value).to eq("google/gemini-2.5-flash:free")
    click_button "Update Runner"
    expect(page).to have_text("Runner updated successfully.")
    expect(runner.reload).to be_zero_data_retention
    expect(runner.config.dig("opencode", "model")).to eq("google/gemini-2.5-flash:free")
    visit edit_runner_path(runner)
    expect(page).to have_checked_field("Require zero data retention")
    expect(find("#runner_model_selection_choice").value).to eq("google/gemini-2.5-flash:free")
  end

  # @spec RUNNER-MODEL-OPTIONS-009
  it "keeps stale endpoint data non-selectable and preserves the ZDR requirement" do
    OpenrouterZdrCatalog.current.update!(last_successful_at: 2.days.ago)
    visit edit_runner_path(runner)
    check "Require zero data retention"
    expect(page).to have_field("runner_model_search", disabled: true)
    expect(page).to have_select("runner_model_selection_choice", disabled: true)
    expect(page).to have_checked_field("Require zero data retention")
    expect(page).to have_text(/stale/i)
  end
end
