# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Cache do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:project) { build_stubbed(:project, id: 42) }
  let(:result) do
    HealthChecks::Result.new(
      findings: [
        HealthChecks::Finding.new(check: "X", scope: :project, severity: :error, message: "broken")
      ],
      checked_at: Time.current,
      duration_ms: 7
    )
  end

  before do
    allow(Rails).to receive(:cache).and_return(memory_store)
  end

  it "round-trips a written Result for the same project" do
    described_class.write(project, result)

    cached = described_class.read(project)
    expect(cached).to be_a(HealthChecks::Result)
    expect(cached.findings.size).to eq(1)
    expect(cached.findings.first.severity).to eq(:error)
    expect(cached.duration_ms).to eq(7)
  end

  it "scopes cached results per project id" do
    other = build_stubbed(:project, id: 99)
    described_class.write(project, result)

    expect(described_class.read(other)).to be_nil
  end

  it "deletes a cached result" do
    described_class.write(project, result)
    described_class.delete(project)

    expect(described_class.read(project)).to be_nil
  end
end
