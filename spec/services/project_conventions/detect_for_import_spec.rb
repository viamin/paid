# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::DetectForImport do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }
  let(:branch) { "main" }
  let(:worktree_service) { instance_double(WorktreeService) }

  before do
    allow(WorktreeService).to receive(:new).with(project).and_return(worktree_service)
    Knowledge::CollectorRunner.reset_registry!
    Knowledge::CollectorRunner.register("project_conventions", Knowledge::Collectors::ProjectConventionsCollector)
  end

  after do
    Knowledge::CollectorRunner.reset_registry!
  end

  it "runs the project conventions collector against a temporary checkout" do
    Dir.mktmpdir do |dir|
      Pathname(dir).join("release-please-config.json").write('{"packages":{".":{}}}')
      Pathname(dir).join("bin").mkpath
      Pathname(dir).join("bin/ci").write("#!/usr/bin/env bash\nbundle exec rspec\n")

      allow(worktree_service).to receive(:with_temporary_checkout).with(commit_sha).and_yield(dir)

      result = described_class.call(project:, commit_sha:, branch:)

      expect(result[:results]).to contain_exactly(
        hash_including(collector_type: "project_conventions", status: "completed")
      )

      detection = project.project_convention_detections.find_by!(key: "commit_style")
      expect(detection.project_version.commit_sha).to eq(commit_sha)
      expect(detection.value).to include("type" => "conventional_commits")
    end
  end
end
