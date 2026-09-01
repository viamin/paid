# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-LINT-001
RSpec.describe Knowledge::Quality::Checks::StaleScopePath do
  let(:project) { create(:project) }

  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, :completed, project_version: project_version, collector_type: "routes") }

  it "produces zero findings when the bare repo is unavailable" do
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb")

    worktree_service = instance_double(WorktreeService)
    allow(worktree_service).to receive(:tracked_files).and_raise(WorktreeService::Error, "no repo")
    allow(WorktreeService).to receive(:new).and_return(worktree_service)

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "produces zero findings when tracked_files returns an empty set" do
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb")

    worktree_service = instance_double(WorktreeService, tracked_files: Set.new)
    allow(WorktreeService).to receive(:new).and_return(worktree_service)

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "flags artifacts whose scope_path is not present in HEAD" do
    artifact = create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb")

    check = described_class.new(project: project)
    allow(check).to receive(:tracked_files).and_return(Set["config/routes.rb"])
    allow(check).to receive(:file_exists?).with(artifact.scope_path).and_return(false)

    findings = check.findings
    expect(findings.size).to eq(1)
    expect(findings.first).to include(code: "stale_scope_path", target_id: artifact.id.to_s)
  end

  it "skips artifacts without a scope_path" do
    create(:knowledge_artifact, project: project, collector_run: collector_run, scope_path: nil)

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "does not flag deleted or stale artifacts" do
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb", status: "stale")
    create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb", status: "deleted")

    findings = described_class.new(project: project).findings
    expect(findings).to be_empty
  end

  it "lists the HEAD tree once and checks membership in-memory, regardless of artifact count" do
    present = create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "config/routes.rb")
    missing = create(:knowledge_artifact, project: project, collector_run: collector_run,
      scope_path: "app/controllers/missing.rb")

    worktree_service = instance_double(WorktreeService, tracked_files: Set["config/routes.rb"])
    allow(WorktreeService).to receive(:new).and_return(worktree_service)

    findings = described_class.new(project: project).findings

    expect(worktree_service).to have_received(:tracked_files).once
    expect(findings.map { |f| f[:target_id] }).to contain_exactly(missing.id.to_s)
    expect(findings.map { |f| f[:target_id] }).not_to include(present.id.to_s)
  end
end
