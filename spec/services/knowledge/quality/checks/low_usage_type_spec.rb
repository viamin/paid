# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Knowledge::Quality::Checks::LowUsageType do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }

  it "flags artifact types with zero recent retrieval usage" do
    run = create(:agent_run, :completed, project: project)
    create(:knowledge_usage_stat, agent_run: run, project: project,
      artifact_type: "route", artifact_count: 5)

    collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "schema")
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "schema", status: "active")

    findings = described_class.new(project: project).findings
    expect(findings.map { |f| f[:detail] }).to include(include("no retrieval usage"))
    expect(findings.map { |f| f[:target_id] }).to include("schema")
  end

  it "does not flag artifact types with active usage in the window" do
    run = create(:agent_run, :completed, project: project)
    create(:knowledge_usage_stat, agent_run: run, project: project,
      artifact_type: "route", artifact_count: 5)

    collector_run = create(:collector_run, :completed, project_version: project_version, collector_type: "routes")
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      artifact_type: "route", status: "active")

    findings = described_class.new(project: project).findings
    type_findings = findings.select { |f| f[:target_id] == "route" }
    expect(type_findings).to be_empty
  end
end
