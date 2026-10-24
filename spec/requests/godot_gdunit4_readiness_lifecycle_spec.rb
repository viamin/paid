# frozen_string_literal: true

require "rails_helper"
require "open3"
require "ostruct"

# @spec PROJECT-READINESS-005, PROJECT-READINESS-007, PROJECT-READINESS-008, PROJECT-READINESS-009, PROJECT-READINESS-013, TDD-GUARD-003
RSpec.describe "Godot/gdUnit4 readiness lifecycle" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) do
    create(:project, account:, created_by: user, primary_language: "GDScript", tdd_mode: "strict")
  end
  let(:missing_fixture) { Rails.root.join("spec/fixtures/projects/forager-ios") }
  let(:ready_fixture) { Pathname(ENV.fetch("GODOT_GDUNIT4_FIXTURE_PATH", Rails.root.join("spec/fixtures/projects/godot-gdunit4-ready"))) }

  it "moves from pending bootstrap to a cleared Inbox entry after merged target-branch evidence" do
    Projects::Readiness::Record.call(project:, repo_path: missing_fixture)

    expect(Inbox::Queue.call(user:, kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND).map(&:project)).to eq([ project ])

    bootstrap_run = start_bootstrap_run
    expect_bootstrap_write_boundary
    expect_merged_bootstrap_to_clear_inbox(bootstrap_run)
    expect_red_draft_write_guard
  end

  it "reports the intentionally red gdUnit4 draft command outcome", :godot_gdunit4 do
    skip "set GODOT_GDUNIT4_FIXTURE_PATH and GODOT_BIN to run the real gdUnit4 acceptance command" unless godot_acceptance_environment?

    output, status = Open3.capture2e(
      { "GODOT_BIN" => ENV.fetch("GODOT_BIN") },
      "bin/test", chdir: ready_fixture
    )

    expect(status).not_to be_success
    expect(output).to include("test_intentionally_red_draft")
  end

  private

  def merged_pull_request
    OpenStruct.new(
      id: 4463,
      number: 4463,
      title: "Bootstrap gdUnit4",
      body: "",
      html_url: "https://github.com/example/godot/pull/4463",
      state: "closed",
      state_reason: "completed",
      labels: [],
      pull_request: OpenStruct.new(html_url: "https://github.com/example/godot/pull/4463"),
      user: OpenStruct.new(login: "trusted-user"),
      created_at: Time.current,
      updated_at: Time.current
    )
  end

  def start_bootstrap_run
    sign_in user
    expect {
      post bootstrap_readiness_project_agent_runs_path(project)
    }.to change(AgentRun, :count).by(1)

    AgentRun.last.tap do |run|
      expect(run).to have_attributes(goal: "bootstrap_readiness", trigger_type: "manual")
      expect(run.custom_prompt).to include("runnable godot test command")
    end
  end

  def expect_bootstrap_write_boundary
    guard = Projects::Readiness::BootstrapWriteGuard.call(changed_files: [
      ".github/workflows/gdunit.yml", "project.godot", "addons/gdUnit4/plugin.cfg", "tests/.gitkeep"
    ])

    expect(guard).to be_valid
  end

  def expect_merged_bootstrap_to_clear_inbox(bootstrap_run)
    bootstrap_run.update!(pull_request_number: 4463)
    expect {
      Issues::UpsertFromGithub.call(project:, github_issue: merged_pull_request,
        github_pull_request: OpenStruct.new(merged_at: Time.current))
    }.to have_enqueued_job(EvaluateProjectReadinessJob).with(project.id)

    Projects::Readiness::Record.call(project:, repo_path: ready_fixture)
    expect(Inbox::Queue.call(user:, kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND)).to be_empty
  end

  def expect_red_draft_write_guard
    run = create(:agent_run, project:, tdd_phase: "test_writing")
    guard = Tdd::WriteGuard.call(agent_run: run, changed_files: [ "tests/test_intentionally_red.gd" ])

    expect(guard).to be_valid
  end

  def godot_acceptance_environment?
    ready_fixture.join("addons/gdUnit4/bin/GdUnitCmdTool.gd").file? &&
      File.executable?(ENV.fetch("GODOT_BIN", ""))
  end
end
