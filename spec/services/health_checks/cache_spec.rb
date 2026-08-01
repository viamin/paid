# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Cache do
  let(:project) { build_stubbed(:project) }
  let(:result) do
    HealthChecks::Result.new(findings: [], checked_at: Time.current, duration_ms: 5)
  end

  it "writes and reads a Result round-trip" do
    store = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(store)

    described_class.write(project, result)
    expect(described_class.read(project)).to eq(result)
  end

  it "keys entries by project id" do
    expect(Rails.cache).to receive(:write).with("health_check/project/#{project.id}", result)
    described_class.write(project, result)
  end

  it "returns nil when nothing is cached" do
    expect(described_class.read(project)).to be_nil
  end

  it "deletes a cached entry" do
    expect(Rails.cache).to receive(:delete).with("health_check/project/#{project.id}")
    described_class.delete(project)
  end
end
