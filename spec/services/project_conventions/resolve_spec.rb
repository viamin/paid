# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::Resolve do
  let(:project) { create(:project) }

  it "falls back to defaults when no detection or override exists" do
    result = described_class.call(project:, key: "issue_dependency_format")

    expect(result[:source]).to eq("default")
    expect(result[:value]["depends_on_prefix"]).to eq("Depends on")
  end

  it "uses detected conventions when available" do
    create(:project_convention_detection,
      project: project,
      category: "hook_system",
      key: "hook_manager",
      value: { "type" => "husky", "path" => ".husky", "required" => true })

    result = described_class.call(project:, key: "hook_manager")

    expect(result[:source]).to eq("detection")
    expect(result[:value]).to include("type" => "husky", "path" => ".husky")
  end

  it "prefers enabled overrides and reports drift against detections" do
    create(:project_convention_detection,
      project: project,
      key: "commit_style",
      value: { "type" => "conventional_commits", "required" => true, "default_type" => "feat" })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      value: { "type" => "plain", "fallback_subject" => "Apply Paid changes" })

    result = described_class.call(project:, key: "commit_style")

    expect(result[:source]).to eq("override")
    expect(result[:conflict]).to include(status: "override_applied")
    expect(result[:value]).to include("type" => "plain", "fallback_subject" => "Apply Paid changes")
  end

  it "returns defaults when the override is ignore mode" do
    create(:project_convention_detection,
      project: project,
      key: "commit_style",
      value: { "type" => "conventional_commits", "required" => true, "default_type" => "feat" })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      value: { "type" => "plain" },
      mode: "ignore")

    result = described_class.call(project:, key: "commit_style")

    expect(result[:source]).to eq("override")
    expect(result[:enabled]).to be(false)
    expect(result[:value]).to eq(described_class::DEFAULTS["commit_style"].deep_stringify_keys)
  end

  it "preserves default keys when override is enabled with detection present" do
    create(:project_convention_detection,
      project: project,
      key: "commit_style",
      value: { "type" => "conventional_commits", "required" => true })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      value: { "default_type" => "fix" })

    result = described_class.call(project:, key: "commit_style")

    expect(result[:value]).to include("type" => "conventional_commits", "required" => true, "default_type" => "fix")
  end

  it "keeps detected runtime values while surfacing warning-mode conflicts" do
    create(:project_convention_detection,
      project: project,
      key: "commit_style",
      value: { "type" => "conventional_commits", "required" => true, "default_type" => "feat" })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      mode: "warn",
      value: { "type" => "plain" })

    result = described_class.call(project:, key: "commit_style")

    expect(result[:source]).to eq("warning")
    expect(result[:value]).to include("type" => "conventional_commits", "required" => true)
    expect(result[:conflict]).to include(status: "override_warning")
  end

  it "builds a canonical resolved profile with conflict summaries" do
    create(:project_convention_detection,
      project: project,
      key: "hook_manager",
      value: { "type" => "lefthook", "path" => "lefthook.yml" })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      value: { "type" => "plain", "fallback_subject" => "Apply Paid changes" })

    profile = described_class.profile(project:)

    expect(profile[:conventions].keys).to include("commit_style", "hook_manager", "issue_dependency_format")
    expect(profile[:conventions].fetch("hook_manager")).to include(source: "detection")
    expect(profile[:conflicts].map { |conflict| conflict[:key] }).to include("commit_style")
  end
end
