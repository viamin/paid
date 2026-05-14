# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provider, :no_db do
  it "keeps the legacy provider constants available" do
    expect(described_class < Runner).to be(true)
    expect(ProviderState < RunnerState).to be(true)
  end

  it "keeps provider-named associations available on bridged models" do
    expect(User.reflect_on_association(:providers)&.klass).to eq(Runner)
    expect(User.reflect_on_association(:provider_states)&.klass).to eq(RunnerState)
    expect(ProviderApiKey.reflect_on_association(:providers)&.klass).to eq(Runner)
    expect(AgentRun.reflect_on_association(:provider)&.klass).to eq(Runner)
    expect(ChatSession.reflect_on_association(:provider)&.klass).to eq(Runner)
  end

  it "keeps provider-named compatibility methods available" do
    expect(AgentRun).to respond_to(:distinct_effective_provider_options)
    expect(AgentRun).to respond_to(:provider_options_cache_key_for)
    expect(AgentRun).to respond_to(:invalidate_provider_options_cache)
    expect(AgentRun).to respond_to(:preload_final_provider_records)
    expect(UserSetting).to respond_to(:fallback_candidate_providers)
    expect(UserSetting.instance_methods).to include(:provider_priority, :provider_priority_for_goal, :available_providers)
  end
end
