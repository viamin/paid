# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-002
RSpec.describe Knowledge::Quality::Checks::EmbeddingCoverageCritical do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, :completed, project_version: project_version, collector_type: "routes") }

  def create_active_chunks(count, embedded: 0)
    count.times do |n|
      artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
        artifact_type: "route", identifier: "route-#{n}", status: "active")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project,
        embedding_model: n < embedded ? "text-embedding-3-large" : nil)
    end
  end

  it "fires a project-level finding when embedding coverage is at zero across enough active chunks" do
    create_active_chunks(described_class::MIN_ACTIVE_CHUNKS, embedded: 0)

    findings = described_class.new(project: project).findings

    expect(findings.length).to eq(1)
    expect(findings.first[:target_type]).to eq("Project")
    expect(findings.first[:target_id]).to eq(project.id.to_s)
    expect(findings.first[:severity]).to eq("error")
    expect(findings.first[:detail]).to include("0.00%")
  end

  it "does not fire when coverage is well above the near-zero threshold" do
    create_active_chunks(described_class::MIN_ACTIVE_CHUNKS, embedded: described_class::MIN_ACTIVE_CHUNKS)

    findings = described_class.new(project: project).findings

    expect(findings).to be_empty
  end

  it "does not fire for projects below the minimum active chunk count" do
    create_active_chunks(described_class::MIN_ACTIVE_CHUNKS - 1, embedded: 0)

    findings = described_class.new(project: project).findings

    expect(findings).to be_empty
  end
end
