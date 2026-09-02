# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Knowledge::Quality::Checks::DanglingLink do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, :completed, project_version: project_version, collector_type: "routes") }

  it "flags links whose target chunk is soft-deleted" do
    source_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    source_chunk = create(:knowledge_chunk, knowledge_artifact: source_artifact, project: project, status: "active")
    target_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    target_chunk = create(:knowledge_chunk, knowledge_artifact: target_artifact, project: project, status: "active")
    link = create(:knowledge_link, source_chunk: source_chunk, target_chunk: target_chunk)
    target_chunk.update_columns(status: "deleted")

    findings = described_class.new(project: project).findings
    expect(findings.size).to eq(1)
    expect(findings.first).to include(code: "dangling_link", target_id: link.id.to_s)
  end

  it "does not flag links whose target chunk is still active" do
    source_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    source_chunk = create(:knowledge_chunk, knowledge_artifact: source_artifact, project: project, status: "active")
    target_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    target_chunk = create(:knowledge_chunk, knowledge_artifact: target_artifact, project: project, status: "active")
    create(:knowledge_link, source_chunk: source_chunk, target_chunk: target_chunk)

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "does not consider redacted or stale target chunks as dangling" do
    source_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    source_chunk = create(:knowledge_chunk, knowledge_artifact: source_artifact, project: project, status: "active")
    target_artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")
    target_chunk = create(:knowledge_chunk, knowledge_artifact: target_artifact, project: project, status: "redacted")
    create(:knowledge_link, source_chunk: source_chunk, target_chunk: target_chunk)

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end
end
