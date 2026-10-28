# frozen_string_literal: true

require "rails_helper"

# RDR-075 M00 live execution-environment validation (issue #4604).
#
# The 2026-10-23 handoff-validation audit
# (docs/rdrs/audit-report-2026-10-23-rdr-075-m00-tool-handoff-validation.md)
# could not produce the two live artifacts its acceptance criteria require
# because the workspace it ran in had no Docker client or Docker socket. This
# spec produces them in a Docker-capable environment by driving the shipped
# validation contract end to end:
#
#   TechnicalPrerequisites::StartValidation
#     -> TechnicalPrerequisiteValidationJob
#       -> TechnicalPrerequisites::ValidateExecution
#         -> AgentRun#provision_execution_environment
#         -> Containers::GitOperations#clone_and_checkout_pinned_commit
#         -> Containers::McpProvisioner#provision (the tool_sidecar arm)
#         -> AgentRun#execute_in_execution_environment(..., stream: false)
#         -> run/sidecar cleanup
#
# Scenario 1 (native analyzer): a fresh AgentRun pinned to a real commit of
# viamin/paid, with one native CLI analyzer (debride) invoked against a
# bounded, read-only target directory of that pinned checkout.
#
# Scenario 2 (sidecar interaction): a fresh AgentRun carrying an allowlisted
# tool_sidecar, whose documented HTTP endpoint is called from the paired run
# through the same execute_in_execution_environment contract.
#
# Every artifact is printed as a single JSON line (RDR075_ARTIFACT ...) so the
# CI job log is the preserved evidence for the audit report.
RSpec.describe "RDR-075 live execution-environment validation" do
  ARTIFACT_PREFIX = "RDR075_ARTIFACT"

  # The commit that recorded the 2026-10-23 handoff-validation audit, so the
  # pinned checkout is a real, immutable revision of this repository rather
  # than a moving branch head.
  PINNED_SHA = "081b0a19f6f8a1a4b20ef8cafff366b59f9524e7"

  # A CI-built analyzer image: the native CLI analyzer named in RDR-075's
  # research findings (debride) plus the "agent" user and /workspace
  # ownership the shipped container contract expects.
  ANALYZER_IMAGE = "rdr075-debride-analyzer:latest"

  # A representative allowlisted tool_sidecar that serves one documented HTTP
  # endpoint and needs no writable root filesystem.
  SIDECAR_IMAGE = "hashicorp/http-echo:1.0"
  SIDECAR_PORT = 5678

  # A bounded, read-only analyzer target inside the pinned checkout.
  ANALYZER_TARGET = "app/services/marketplace_entries"

  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, owner: "viamin", repo: "paid", created_by: owner)
  end
  let(:issue) { create(:issue, project: project) }
  let(:source_run) do
    create(:agent_run, :completed, project: project, issue: issue, base_commit_sha: PINNED_SHA)
  end

  # Validation runs created by this example group, so cleanup never touches
  # containers that belong to another run.
  let(:validation_run_ids) { [] }

  # This harness talks to a real Docker daemon over its unix socket, so the
  # suite's default "no real connections" WebMock policy has to be lifted for
  # these examples only.
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  before do
    skip("Docker daemon is unavailable in this environment") unless docker_available?

    promote_to_account_owner
    create(:user_setting, user: owner, allowed_service_images: [ SIDECAR_IMAGE ])
    FeatureFlags.enable!(:marketplace_tool_sidecars, project: project)
  end

  after do
    remove_leftover_containers
  end

  it "invokes a native CLI analyzer in a fresh pinned AgentRun execution environment" do
    image_id = build_analyzer_image!
    requirement = create_requirement(name: "RDR-075 native analyzer", command: analyzer_command)

    validation_run = start_validation(requirement:)
    pin_image(validation_run, image_id:)
    evidence = run_validation(validation_run)

    print_artifact(
      scenario: "native_analyzer",
      environment: ci_environment,
      analyzer: {
        name: "debride",
        image: ANALYZER_IMAGE,
        image_id: "sha256:#{image_id}",
        command: analyzer_command,
        target: "/workspace/#{ANALYZER_TARGET}"
      },
      checkout: {
        requested_commit: PINNED_SHA,
        resolved_commit: evidence["checkout"],
        repository: "https://github.com/viamin/paid.git"
      },
      execution: {
        stdout: evidence.dig("native", "stdout"),
        stderr: evidence.dig("native", "stderr"),
        exit_code: evidence.dig("native", "exit_code")
      },
      image_identity: {
        image: evidence["image"],
        digest: evidence["image_digest"]
      },
      cleanup: evidence["cleanup"],
      status: evidence["status"],
      error: evidence["error"],
      run_error: validation_run.error_message
    )

    expect(evidence["status"]).to eq("completed"), "validation failed: #{evidence.inspect}"
    expect(evidence.dig("native", "exit_code")).to eq(0)
    expect(evidence["checkout"]).to eq(PINNED_SHA)
    expect(evidence.dig("cleanup", "completed")).to be(true)
    expect(remaining_containers_for(validation_run)).to be_empty
  end

  it "calls an allowlisted tool_sidecar endpoint from the paired AgentRun" do
    image_id = build_analyzer_image!
    requirement = create_requirement(name: "RDR-075 sidecar probe", command: sidecar_command)

    validation_run = start_validation(requirement:)
    pin_image(validation_run, image_id:)
    attach_tool_sidecar(validation_run)
    evidence = run_validation(validation_run)

    print_artifact(
      scenario: "sidecar_interaction",
      environment: ci_environment,
      sidecar: {
        name: "rdr075-echo",
        image: SIDECAR_IMAGE,
        port: SIDECAR_PORT,
        endpoints: evidence["tool_endpoints"],
        container_ids: evidence["tool_sidecars"]
      },
      checkout: {
        requested_commit: PINNED_SHA,
        resolved_commit: evidence["checkout"]
      },
      execution: {
        stdout: evidence.dig("native", "stdout"),
        stderr: evidence.dig("native", "stderr"),
        exit_code: evidence.dig("native", "exit_code")
      },
      image_identity: {
        image: evidence["image"],
        digest: evidence["image_digest"]
      },
      cleanup: evidence["cleanup"],
      status: evidence["status"],
      error: evidence["error"],
      run_error: validation_run.error_message
    )

    expect(evidence["status"]).to eq("completed"), "validation failed: #{evidence.inspect}"
    expect(evidence.dig("native", "exit_code")).to eq(0)
    expect(evidence["tool_endpoints"]).to be_present
    expect(evidence.dig("cleanup", "completed")).to be(true)
    expect(remaining_containers_for(validation_run)).to be_empty
  end

  private

  # The tool-sidecar image allowlist is read from the account's admin/owner
  # user settings, so the acting user has to hold that role.
  def promote_to_account_owner
    membership = AccountMembership.find_by(account_id: account.id, user_id: owner.id) ||
      create(:account_membership, account: account, user: owner)
    membership.update!(role: :owner)
  end

  def docker_available?
    Containers.backend.ping
    true
  rescue StandardError => e
    Rails.logger.warn(message: "rdr075.docker_unavailable", error: e.message)
    false
  end

  def ci_environment
    {
      ci: ENV["GITHUB_RUN_ID"].present?,
      workflow: ENV["GITHUB_WORKFLOW"],
      run_id: ENV["GITHUB_RUN_ID"],
      run_attempt: ENV["GITHUB_RUN_ATTEMPT"],
      commit: ENV["GITHUB_SHA"],
      ref: ENV["GITHUB_REF"],
      docker_version: Docker.version["Version"],
      backend: Containers.backend.identifier
    }
  end

  # Builds the analyzer image once per run: the native CLI analyzer plus the
  # "agent" user and /workspace ownership that the shipped container contract
  # (ReadonlyRootfs, User: agent, bind-mounted workspace) depends on.
  def build_analyzer_image!
    existing = local_image(ANALYZER_IMAGE)
    return existing.id.delete_prefix("sha256:") if existing

    dockerfile = <<~DOCKERFILE
      FROM ruby:3.3-slim
      RUN apt-get update \\
        && apt-get install -y --no-install-recommends git ca-certificates build-essential \\
        && rm -rf /var/lib/apt/lists/*
      RUN useradd --create-home --uid 1001 --shell /bin/bash agent \\
        && mkdir -p /workspace \\
        && chown agent:agent /workspace
      RUN gem install debride --no-document
    DOCKERFILE

    Containers.backend.build_image(dockerfile, { "t" => ANALYZER_IMAGE }).id.delete_prefix("sha256:")
  end

  def local_image(name)
    Containers.backend.get_image(name)
  rescue Docker::Error::NotFoundError
    nil
  end

  def create_requirement(name:, command:)
    create(:pre_commit_requirement, :project_level,
      project: project, name: name, command: command,
      check_type: "shell_command", failure_behavior: "warn", position: 0)
  end

  def start_validation(requirement:)
    result = TechnicalPrerequisites::StartValidation.call(
      source_run: source_run, requirement: requirement, actor: owner
    )
    raise "validation not queued: #{result.message}" unless result.success?

    validation_run_ids << result.agent_run.id
    result.agent_run
  end

  # Records the runtime image the run actually executes in, so the evidence
  # carries the image identity (reference plus content id) of the container
  # the analyzer ran inside.
  def pin_image(validation_run, image_id:)
    validation_run.record_runtime_image_selection!(
      "requested_image" => ANALYZER_IMAGE,
      "resolved_image" => ANALYZER_IMAGE,
      "digest" => "sha256:#{image_id}",
      "architecture" => "amd64",
      "immutable" => false
    )
    validation_run.reload
  end

  def attach_tool_sidecar(validation_run)
    AgentRun.where(id: validation_run.id).update_all(
      tool_sidecar_snapshot: [
        {
          "name" => "rdr075-echo",
          "image" => SIDECAR_IMAGE,
          "port" => SIDECAR_PORT,
          "env" => {}
        }
      ]
    )
    validation_run.reload
  end

  def run_validation(validation_run)
    TechnicalPrerequisiteValidationJob.perform_now(validation_run.id)
    validation_run.reload
    validation_run.verification_result.fetch(TechnicalPrerequisites::EVIDENCE_KEY, {})
  end

  def analyzer_command
    "debride /workspace/#{ANALYZER_TARGET}"
  end

  # Reads the sidecar endpoint the platform published to the run and calls
  # it over HTTP from inside the run container.
  def sidecar_command
    <<~SHELL.strip
      ruby -rnet/http -rjson -e 'endpoints = JSON.parse(ENV.fetch("PAID_TOOL_SIDECAR_ENDPOINTS")); endpoint = endpoints.first; response = Net::HTTP.get_response(URI(endpoint.fetch("url"))); puts "endpoint=\#{endpoint.fetch("url")}"; puts "status=\#{response.code}"; puts "body=\#{response.body}"'
    SHELL
  end

  def remaining_containers_for(agent_run)
    Containers.backend.list_containers(all: true).select do |container|
      container.info.dig("Labels", "paid.agent_run_id") == agent_run.id.to_s
    end
  end

  def remove_leftover_containers
    validation_run_ids.each do |run_id|
      Containers.backend.list_containers(all: true).each do |container|
        next unless container.info.dig("Labels", "paid.agent_run_id") == run_id.to_s

        Containers.backend.delete_container(container, force: true)
      rescue Docker::Error::DockerError
        nil
      end
    end
  rescue StandardError
    nil
  end

  def print_artifact(**artifact)
    puts "#{ARTIFACT_PREFIX} #{JSON.generate(artifact)}"
  end
end
