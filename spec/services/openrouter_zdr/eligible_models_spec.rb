# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdr::EligibleModels do
  let(:project) { instance_double(Project, llm_provider_allowed?: true) }

  before do
    allow(Runners::ModelCompatibility).to receive(:call).and_return(
      instance_double(Runners::ModelCompatibility::Result, unsupported?: false)
    )
  end

  # @spec FREE-MODEL-SYNC-012
  it "exposes the catalog freshness alongside last-known eligible models" do
    refresh = OpenrouterZdrCatalogRefresh.current
    refresh.update!(last_successful_at: 1.hour.ago, last_attempted_at: Time.current, last_error: "timed out")

    expect(described_class.freshness).to have_attributes(
      last_successful_at: be_within(1.second).of(1.hour.ago),
      last_error: "timed out"
    )
  end

  # @spec FREE-MODEL-SYNC-013
  it "returns only active endpoint-eligible models allowed for the project and runner" do
    eligible = create(:llm_model, model_id: "openai/eligible", provider: "openai", openrouter_zdr_eligible: true)
    create(:llm_model, model_id: "openai/withdrawn", provider: "openai", openrouter_zdr_eligible: false)
    create(:llm_model, :inactive, model_id: "openai/inactive", provider: "openai", openrouter_zdr_eligible: true)

    expect(described_class.call(project: project, runner_key: "opencode", auth_type: "api_key"))
      .to contain_exactly(eligible)
  end

  # @spec FREE-MODEL-SYNC-013
  it "excludes models rejected by the project or runner compatibility policy" do
    model = create(:llm_model, model_id: "openai/eligible", provider: "openai", openrouter_zdr_eligible: true)
    allow(project).to receive(:llm_provider_allowed?).with("openai").and_return(false)

    expect(described_class.call(project: project, runner_key: "opencode", auth_type: "api_key")).to be_empty

    allow(project).to receive(:llm_provider_allowed?).with("openai").and_return(true)
    allow(Runners::ModelCompatibility).to receive(:call).and_return(
      instance_double(Runners::ModelCompatibility::Result, unsupported?: true)
    )

    expect(described_class.call(project: project, runner_key: "opencode", auth_type: "api_key")).not_to include(model)
  end
end
