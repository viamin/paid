# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::VerificationPrompt do
  # @spec LIVE-PREVIEW-005 LIVE-PREVIEW-011
  let(:project) { create(:project, screenshot_settings: { "verification_enabled" => true }) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :with_git_context, project: project, issue: issue) }
  let(:repo_path) { Dir.mktmpdir("verification-prompt-spec") }

  before do
    FileUtils.mkdir_p(File.join(repo_path, ".paid"))
    FileUtils.mkdir_p(File.join(repo_path, "bin"))
    File.write(File.join(repo_path, ".paid/screenshots.yml"), <<~YAML)
      framework: rails
      base_url: http://localhost:3000
      routes:
        - path: /
          name: home
    YAML
    File.write(File.join(repo_path, "bin/rails"), "#!/bin/sh\n")
  end

  after do
    FileUtils.rm_rf(repo_path)
  end

  it "renders a verification contract with app startup guidance and result path" do
    section = described_class.call(agent_run:, repo_path:)

    expect(section.content).to include("# Interactive Verification")
    expect(section.content).to include("http://localhost:3000")
    expect(section.content).to include("bundle exec bin/rails server -b 0.0.0.0 -p 3000")
    expect(section.content).to include(described_class::RESULT_PATH)
    expect(section.content).to include("--data-binary @-")
    expect(section.content).to include("application-diagnostics")
    expect(section.fallback_result).to be_nil
  end

  it "requires criterion evidence references in the recorded result" do
    section = described_class.call(agent_run:, repo_path:)

    expect(section.content).to include('"acceptance_criteria"')
    expect(section.content).to include('"verification"')
    expect(section.content).to include("Do not infer a pass from a test name")
  end

  # @spec LIVE-PREVIEW-011
  it "requires criterion evidence for issue runs when interactive verification is disabled" do
    project.update!(screenshot_settings: { "verification_enabled" => false })

    section = described_class.call(agent_run:, repo_path:)

    expect(section.content).to include("# Acceptance Criterion Evidence")
    expect(section.content).to include('"acceptance_criteria"')
    expect(section.content).not_to include("# Interactive Verification")
    expect(section.fallback_result).to be_nil
  end

  it "does not add criterion evidence to an issue-less run when interactive verification is disabled" do
    project.update!(screenshot_settings: { "verification_enabled" => false })
    agent_run.update!(issue: nil)

    section = described_class.call(agent_run:, repo_path:)

    expect(section.content).to be_empty
    expect(section.fallback_result).to be_nil
  end

  it "produces a skip fallback when no start command can be auto-detected" do
    File.delete(File.join(repo_path, "bin/rails"))

    section = described_class.call(agent_run:, repo_path:)

    expect(section.fallback_result).to include(
      "status" => "skipped",
      "reason" => "app_start_command_unavailable"
    )
    expect(section.content).to include("not auto-detected")
  end
end
