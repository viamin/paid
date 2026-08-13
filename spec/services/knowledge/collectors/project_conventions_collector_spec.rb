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

  def build_collector(version:, run:, path:)
    described_class.new(
      project: project,
      project_version: version,
      collector_run: run,
      options: { scan_path: path.to_s }
    )
  end

  def expect_full_lid_detection!
    expect(project.reload.lid_mode).to eq("full")
    expect(project.lid_detection).to include(
      "version" => "1.3.0",
      "sources" => [ "AGENTS.md ## LID block" ]
    )
  end

  it "stores convention artifacts and syncs first-class detections" do
    fixture_path.join("AGENTS.md").write("## LID\n\n- Mode: Full\n- Version: 1.3.0\n")

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
    expect_full_lid_detection!
  end

  it "creates a first-class project convention recommendation for detected hook managers" do
    collector.collect

    recommendation = project.project_convention_recommendations.find_by!(
      convention_key: "hook_manager",
      action_type: "open_pr"
    )

    expect(recommendation.description).to include("Detected lefthook hooks")
    expect(recommendation.evidence["detected_value"]).to include("type" => "lefthook")
    expect(recommendation.evidence.dig("strategy", "manager_type")).to eq("lefthook")
    expect(project.knowledge_recommendations).to be_empty
  end

  it "stores category metadata on emitted artifacts" do
    artifact = collector.collect.find { |item| item[:identifier] == "hook_manager" }

    expect(artifact.dig(:metadata, :category)).to eq("hook_system")
  end

  it "refreshes detections per project version when repository conventions change" do
    collector.collect
    second_project_version = create(:project_version, project: project)
    second_collector_run = create(:collector_run, project_version: second_project_version, collector_type: "project_conventions")
    second_fixture_path = build_husky_fixture

    build_collector(version: second_project_version, run: second_collector_run, path: second_fixture_path).collect

    first_detection = project.project_convention_detections.find_by!(project_version: project_version, key: "hook_manager")
    second_detection = project.project_convention_detections.find_by!(project_version: second_project_version, key: "hook_manager")

    expect(first_detection.value).to include("type" => "lefthook")
    expect(second_detection.value).to include("type" => "husky")
  ensure
    FileUtils.rm_rf(second_fixture_path) if defined?(second_fixture_path)
  end

  def build_husky_fixture
    Pathname(Dir.mktmpdir).tap do |path|
      path.join(".husky").mkpath
      path.join("bin").mkpath
      path.join("bin/ci").write("#!/usr/bin/env bash\nbundle exec rspec\n")
    end
  end
end
