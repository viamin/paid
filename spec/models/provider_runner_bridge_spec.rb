# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provider, :no_db do
  it "keeps the legacy provider constants available" do
    expect(described_class < Runner).to be(true)
    expect(ProviderState < RunnerState).to be(true)
  end

  it "keeps provider-named associations available on bridged models" do
    expect(User.reflect_on_association(:providers)&.klass).to eq(described_class)
    expect(User.reflect_on_association(:provider_states)&.klass).to eq(ProviderState)
    expect(ProviderApiKey.reflect_on_association(:providers)&.klass).to eq(described_class)
    expect(AgentRun.reflect_on_association(:provider)&.klass).to eq(described_class)
    expect(ChatSession.reflect_on_association(:provider)&.klass).to eq(described_class)
  end

  it "keeps provider-named compatibility methods available" do
    expect(AgentRun).to respond_to(:distinct_effective_provider_options)
    expect(AgentRun).to respond_to(:provider_options_cache_key_for)
    expect(AgentRun).to respond_to(:invalidate_provider_options_cache)
    expect(AgentRun).to respond_to(:preload_final_provider_records)
    expect(UserSetting).to respond_to(:fallback_candidate_providers)
    expect(UserSetting.instance_methods).to include(
      :provider_priority,
      :default_provider_identifier,
      :default_provider_identifier_for_goal,
      :select_automated_provider_identifier,
      :provider_priority_for_goal,
      :available_providers,
      :provider_state_for
    )
    expect(UserSetting.private_instance_methods).to include(:identifiers_for_provider_token)
  end

  it "keeps legacy provider routing-key identifiers readable during the bridge" do
    expect(Runner.routing_key?("provider:123")).to be(true)
    expect(Runner.id_from_routing_key("provider:123")).to eq(123)
  end

  it "keeps provider-named controller, helper, policy, service, and job constants available" do
    expect(ProvidersController < RunnersController).to be(true)
    expect(ProvidersHelper.included_modules).to include(RunnersHelper)
    expect(ProviderPolicy < RunnerPolicy).to be(true)
    expect(AgentRuns::ProviderResolver < AgentRuns::RunnerResolver).to be(true)
    expect(AgentRuns::ProviderSelectionLogger < AgentRuns::RunnerSelectionLogger).to be(true)
    expect(Dashboard::ProviderHealth < Dashboard::RunnerHealth).to be(true)
    expect(Notifications::CheckProviderQuotasJob).to be < ApplicationJob
  end
end
