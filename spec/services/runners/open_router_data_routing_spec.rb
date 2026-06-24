# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::OpenRouterDataRouting do
  # The routing module is mixed into both OpenRouter execution plans; exercise
  # it through a minimal host so the classification→routing mapping is asserted
  # once, independent of either plan's model/base_url plumbing.
  let(:host) do
    Class.new do
      include Runners::OpenRouterDataRouting
    end.new
  end

  def project_with(classification)
    Struct.new(:data_classification).new(classification)
  end

  it "allows data collection for open classification" do
    expect(host.build_provider_routing(project_with("open"))).to eq(data_collection: "allow")
  end

  it "allows data collection for internal classification" do
    expect(host.build_provider_routing(project_with("internal"))).to eq(data_collection: "allow")
  end

  it "denies data collection for confidential classification" do
    expect(host.build_provider_routing(project_with("confidential"))).to eq(data_collection: "deny")
  end

  it "denies data collection and enables zdr for restricted classification" do
    expect(host.build_provider_routing(project_with("restricted"))).to eq(data_collection: "deny", zdr: true)
  end

  it "falls back to allow for an unknown classification" do
    expect(host.build_provider_routing(project_with("top-secret"))).to eq(data_collection: "allow")
  end

  it "treats a blank classification as internal (allow)" do
    expect(host.build_provider_routing(project_with(nil))).to eq(data_collection: "allow")
  end

  it "treats a project without data_classification as internal (allow)" do
    expect(host.build_provider_routing(Struct.new(:name).new("nope"))).to eq(data_collection: "allow")
  end

  it "treats a nil project as internal (allow)" do
    expect(host.build_provider_routing(nil)).to eq(data_collection: "allow")
  end

  it "exposes the default classification constant" do
    expect(described_class::DEFAULT_DATA_CLASSIFICATION).to eq("internal")
  end
end
