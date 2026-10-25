# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrerequisiteExecutions::Start do # @spec PREREQ-EXEC-005 # @spec PREREQ-EXEC-006 # @spec PREREQ-EXEC-014
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project, github_number: 4604) }
  let(:enqueued) { [] }
  let(:enqueuer) { ->(validation) { enqueued << validation.id } }

  before do
    FeatureFlags.flipper.features.each(&:remove)
    create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
  end

  def start_validation(**overrides)
    described_class.call(
      project: project,
      issue: issue,
      actor: user,
      branch: "main",
      native_command: "bin/lint",
      enqueuer: enqueuer,
      **overrides
    )
  end

  describe "input validation" do
    it "refuses a blank analyzer command" do
      expect { start_validation(native_command: "  ") }.to raise_error(described_class::InvalidError, /analyzer command/)
    end

    it "refuses a branch with shell-hostile characters" do
      expect { start_validation(branch: "main; rm -rf") }.to raise_error(described_class::InvalidError, /Branch/)
    end

    it "refuses a prerequisite that is not an open issue of the project" do
      expect { start_validation(issue: create(:issue, :pull_request, project: project)) }
        .to raise_error(described_class::InvalidError, /not an open issue/)
      expect { start_validation(issue: create(:issue, project: create(:project, account: account))) }
        .to raise_error(described_class::InvalidError, /open issue of this project/)
    end
  end

  # @spec PREREQ-EXEC-006
  it "creates one bounded validation pinned to the branch with an explicit contract" do
    result = start_validation

    expect(result).to be_started
    validation = result.validation
    expect(validation.status).to eq("pending")
    expect(validation.branch).to eq("main")
    expect(validation.scope_digest).to be_present
    expect(validation.contract["native_command"]).to eq("bin/lint")
    expect(validation.contract["steps"]).to include(hash_including("key" => "native_analyzer"))
    expect(validation.capability_snapshot["environment_available"]).to be(true)
    expect(enqueued).to eq([ validation.id ])
  end

  it "executes on a synthetic internal-agent run pinned to the same branch" do
    validation = start_validation.validation

    run = validation.agent_run
    expect(run.goal).to eq("prerequisite_validation")
    expect(run).to be_synthetic
    expect(run.agent_type).to eq("internal_agent")
    expect(run.branch_name).to eq("main")
    expect(run.initiating_user).to eq(user)
  end

  it "is idempotent while an attempt is active" do
    first = start_validation

    second = start_validation

    expect(second.outcome).to eq(:existing_active)
    expect(second.validation).to eq(first.validation)
    expect(project.prerequisite_execution_validations.count).to eq(1)
    expect(enqueued).to eq([ first.validation.id ])
  end

  # @spec PREREQ-EXEC-005
  it "records unavailable with the exact authorized actions instead of provisioning when a requirement is missing" do
    FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)
    tool = tool_entry(image: "acme/analyzer:latest")

    result = start_validation(marketplace_entry_id: tool.id)

    expect(result).to be_unavailable
    validation = result.validation
    expect(validation.status).to eq("unavailable")
    expect(validation.agent_run).to be_nil
    expect(validation.missing_requirements.sole["authorized_action"]).to include("allowed service images")
    expect(enqueued).to be_empty
  end

  it "refuses a selected entry that is not a tool" do
    skill = create(:marketplace_entry, account: account, entry_type: "skill")

    expect { start_validation(marketplace_entry_id: skill.id) }
      .to raise_error(described_class::InvalidError, /not a tool/)
  end

  describe "retry semantics" do
    # @spec PREREQ-EXEC-014
    it "returns existing evidence for a succeeded attempt of the same scope" do
      first = start_validation
      first.validation.update!(status: "succeeded", finished_at: Time.current)

      second = start_validation

      expect(second.outcome).to eq(:existing_succeeded)
      expect(second.validation).to eq(first.validation)
      expect(project.prerequisite_execution_validations.count).to eq(1)
      expect(enqueued).to eq([ first.validation.id ])
    end

    it "refreshes an unchanged unavailable attempt in place without provisioning" do
      project.account.docker_hosts.update_all(enabled: false)
      first = start_validation
      expect(first).to be_unavailable

      project.account.docker_hosts.update_all(enabled: true, readiness_status: "ready")
      project.account.docker_hosts.update_all(enabled: false)

      second = start_validation

      expect(second.outcome).to eq(:unavailable)
      expect(second.validation).to eq(first.validation)
      expect(project.prerequisite_execution_validations.count).to eq(1)
      expect(enqueued).to be_empty
    end

    it "starts a real attempt when host readiness recovers without an authorization change" do
      project.account.docker_hosts.update_all(enabled: false)
      first = start_validation
      expect(first).to be_unavailable

      project.account.docker_hosts.update_all(enabled: true)

      second = start_validation

      expect(second).to be_started
      expect(project.prerequisite_execution_validations.where(status: "unavailable")).to be_empty
      expect(enqueued).to eq([ second.validation.id ])
    end

    it "starts a fresh attempt and marks prior evidence stale when the scope changes" do
      first = start_validation
      first.validation.update!(status: "failed", finished_at: Time.current)

      second = start_validation(native_command: "bin/lint -a")

      expect(second).to be_started
      expect(second.validation).not_to eq(first.validation)
      expect(first.validation.reload).to be_stale
      expect(second.validation).not_to be_stale
    end

    it "treats a tool-flag change as a scope change so enabling the flag revalidates" do
      tool = tool_entry(image: "acme/analyzer:latest")
      user.add_role(:owner, account)
      create(:user_setting, user: user, allowed_service_images: [ "acme/analyzer:latest" ])

      first = start_validation(marketplace_entry_id: tool.id)
      expect(first).to be_unavailable

      FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)
      second = start_validation(marketplace_entry_id: tool.id)

      expect(second).to be_started
      expect(first.validation.reload).to be_stale
      expect(second.validation.contract.dig("tool", "image")).to eq("acme/analyzer:latest")
    end
  end

  def tool_entry(image:)
    entry = create(:marketplace_entry, account: account, entry_type: "tool", name: "Analyzer Tool")
    version = create(:marketplace_entry_version,
      marketplace_entry: entry,
      canonical_artifact: {
        "install_type" => "tool",
        "image" => image,
        "port" => 8080
      })
    entry.update!(current_version: version)
    entry.reload
  end
end
