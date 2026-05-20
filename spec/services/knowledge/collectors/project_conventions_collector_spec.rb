# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::ProjectConventionsCollector do
  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version, collector_type: "project_conventions") }
  let(:fixture_path) { Pathname(RSpec.current_example.metadata.fetch(:tmpdir)) }
  let(:collector) do
    described_class.new(
      project: project,
      project_version: project_version,
      collector_run: collector_run,
      options: { scan_path: fixture_path.to_s }
    )
  end

  around do |example|
    Dir.mktmpdir do |dir|
      example.metadata[:tmpdir] = dir
      example.run
    end
  end

  before do
    fixture_path.join("release-please-config.json").write('{"packages":{".":{}}}')
    fixture_path.join("lefthook.yml").write("pre-commit:\n  commands: {}\n")
    fixture_path.join("bin").mkpath
    fixture_path.join("bin/ci").write("#!/usr/bin/env bash\nbundle exec rspec\n")
  end

  it "stores convention artifacts and syncs first-class detections" do
    artifacts = collector.collect

    expect(artifacts.map { |artifact| artifact[:identifier] }).to include(
      "release_automation",
      "commit_style",
      "pr_title_style",
      "hook_manager",
      "ci_entrypoint"
    )
    expect(project.project_convention_detections.pluck(:key)).to include(
      "release_automation",
      "commit_style",
      "pr_title_style",
      "hook_manager",
      "ci_entrypoint"
    )
  end

  it "creates a project-convention recommendation for detected hook managers" do
    collector.collect

    recommendation = project.knowledge_recommendations.find_by!(
      recommendation_type: "project_convention",
      collector_type: "project_conventions"
    )

    expect(recommendation.description).to include("Repository manages hooks with lefthook")
    expect(recommendation.evidence["convention_key"]).to eq("hook_manager")
  end
end
