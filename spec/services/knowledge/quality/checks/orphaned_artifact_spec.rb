# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Knowledge::Quality::Checks::OrphanedArtifact do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, :completed, project_version: project_version, collector_type: "routes") }

  it "flags active artifacts with zero chunks" do
    artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")

    findings = described_class.new(project: project).findings
    expect(findings.size).to eq(1)
    expect(findings.first).to include(code: "orphaned_artifact", target_id: artifact.id.to_s)
  end

  it "flags active artifacts whose chunks are all deleted" do
    artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "deleted")

    findings = described_class.new(project: project).findings
    expect(findings.size).to eq(1)
    expect(findings.first).to include(code: "orphaned_artifact", target_id: artifact.id.to_s)
  end

  it "does not flag artifacts that still have active chunks" do
    artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "active")

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "does not flag deleted or stale artifacts" do
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "stale")
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "deleted")

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end
end
