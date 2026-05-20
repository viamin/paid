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
    expect(result[:drift]).to be(true)
    expect(result[:value]).to include("type" => "plain", "fallback_subject" => "Apply Paid changes")
  end

  it "returns defaults when the override is disabled" do
    create(:project_convention_detection,
      project: project,
      key: "commit_style",
      value: { "type" => "conventional_commits", "required" => true, "default_type" => "feat" })
    create(:project_convention_override,
      project: project,
      key: "commit_style",
      value: { "type" => "plain" },
      enabled: false)

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
end
