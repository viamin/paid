# frozen_string_literal: true

require "rails_helper"
require "psych"
require "open3"

class CiWorkflowFile < Pathname
end

RSpec.describe CiWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/ci.yml"),
      aliases: true
    )
  end

  let(:openapi_schema) do
    Psych.safe_load_file(Rails.root.join("docs/api/openapi.yaml"), aliases: true)
  end

  let(:mobile_pact) do
    JSON.parse(Rails.root.join("docs/api/pacts/paid-mobile-api-schema.pact.json").read)
  end

  let(:postgres_pin_step) do
    workflow.fetch("jobs").fetch("lint").fetch("steps")
      .find { |step| step["name"] == "Verify Postgres image pins and client install sources are in sync" }
  end

  # @spec TEST-SUITE-003
  it "assigns every shard index an isolated set of test services" do
    job = workflow.fetch("jobs").fetch("test-shards")
    count = Integer(job.fetch("env").fetch("RSPEC_SHARD_COUNT"))
    expect(job.fetch("strategy").fetch("matrix").fetch("shard")).to eq((0...count).to_a)
    expect(job.fetch("strategy").fetch("fail-fast")).to be(false)
    expect(job.fetch("env").fetch("RSPEC_SHARD_INDEX")).to eq("${{ matrix.shard }}")
    expect(job.fetch("services").keys).to include("postgres", "qdrant")
  end

  # @spec TEST-SUITE-006
  it "fails the stable test check when any shard fails or is cancelled" do
    job = workflow.fetch("jobs").fetch("test")
    expect(job.fetch("needs")).to eq("test-shards")
    expect(job.fetch("if")).to include("always()")
    gate = job.fetch("steps").first.fetch("run")
    %w[success failure cancelled skipped].each do |result|
      _stdout, _stderr, status = Open3.capture3({ "SHARD_RESULT" => result }, "sh", "-c", gate)
      expect(status.success?).to eq(result == "success")
    end
  end

  it "passes the expected test credentials to the database-backed ci jobs" do
    jobs = workflow.fetch("jobs")

    expect(jobs.fetch("test-shards").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_DEVELOPMENT_DATABASE" => "paid_test",
      "PAID_DEVELOPMENT_CABLE_DATABASE" => "paid_test",
      "PAID_TEST_DATABASE" => "paid_test"
    )
    expect(jobs.fetch("performance").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_DEVELOPMENT_DATABASE" => "paid_test",
      "PAID_DEVELOPMENT_CABLE_DATABASE" => "paid_test",
      "PAID_TEST_DATABASE" => "paid_test"
    )
  end


  it "verifies workflow jobs install the matching PGDG postgres client major package" do
    lint_step = postgres_pin_step

    expect(lint_step.fetch("run")).to include('workflow_client="postgresql-client-${major}"')
    expect(lint_step.fetch("run")).to include(
      'check_contains .github/workflows/ci.yml "$workflow_client" ".github/workflows/ci.yml must install $workflow_client"'
    )
    expect(lint_step.fetch("run")).to include(
      'check_contains .github/workflows/ci.yml "apt.postgresql.org/pub/repos/apt" ".github/workflows/ci.yml must install PostgreSQL client tools from PGDG"'
    )
  end

  # PGDG's package revision is not derivable from the upstream version: the
  # same release ships as +1 for one version and +2 for the next, so a check
  # that hardcodes the revision rejects correct pins.
  #
  # @spec TOOLCHAIN-PIN-024
  it "matches the image client package revision instead of assuming it" do
    run = postgres_pin_step.fetch("run")

    expect(run).to include(%q(printf 'postgresql-client-%s=%s-[0-9]+\\\\.pgdg%s\\\\+[0-9]+'))
    expect(run).to include(%q(check_matches .devcontainer/Dockerfile "$bookworm_client"))
    expect(run).to include(%q(check_matches Dockerfile "$trixie_client"))
    expect(run).to include(%q(check_matches docker/agent/Dockerfile "$noble_client"))
    expect(run).not_to include(%q(pgdg12+1"))
  end

  # @spec TOOLCHAIN-PIN-024
  it "ties every image client package to the pinned server version" do
    run = postgres_pin_step.fetch("run")

    expect(run).to include(%q(escaped_version="${version//./\\\\.}"))
    expect(run).to include(%q{bookworm_client="$(client_pattern 12)"})
    expect(run).to include(%q{trixie_client="$(client_pattern 13)"})
    expect(run).to include(%q{noble_client="$(client_pattern 24\\\\.04)"})
  end

  it "installs ast-grep into a user-writable directory during the test job" do
    install_step = workflow.fetch("jobs").fetch("test-shards").fetch("steps")
      .find { |step| step["name"] == "Install ast-grep" }

    expect(install_step.fetch("run")).to include('mkdir -p "$HOME/.local/bin"')
    expect(install_step.fetch("run")).to include('echo "$HOME/.local/bin" >> "$GITHUB_PATH"')
    expect(install_step.fetch("run")).to include('INSTALL_DIR="$HOME/.local/bin" bin/install-ast-grep')
  end

  it "fetches full git history for the test job checkout" do
    checkout_step = workflow.fetch("jobs").fetch("test-shards").fetch("steps")
      .find { |step| step["name"] == "Checkout code" }

    expect(checkout_step.fetch("with")).to include(
      "fetch-depth" => 0,
      "persist-credentials" => false
    )
  end

  # @spec MOBILE-API-017 MOBILE-API-018
  it "prepares a Rails app for mobile contract verification" do
    contract_jobs.each do |job|
      expect(job.fetch("env")).to include("RAILS_ENV" => "test")
      expect(job_steps(job)).to include("Set up database", "Create mobile API bearer token", "Start Rails server")
    end
  end

  # @spec MOBILE-API-017
  it "verifies the mobile consumer Pact" do
    expect(step_run(pact_job, "Verify mobile consumer Pact")).to include(
      "pact_provider_verifier_compatibility", "pact-provider-verifier", "docs/api/pacts/paid-mobile-api-schema.pact.json",
      "--provider-base-url=http://127.0.0.1:3000", "--fail-if-no-pacts-found"
    )
  end

  # @spec MOBILE-API-017
  it "declares Rails' JSON content type for the interim Pact response" do
    response = mobile_pact.fetch("interactions").first.fetch("response")

    expect(response.fetch("headers")).to include("Content-Type" => "application/json; charset=utf-8")
  end

  # @spec MOBILE-API-018
  it "fuzzes only the selected safe mobile API operations" do
    fuzz_command = step_run(schemathesis_job, "Fuzz mobile API contract")

    expect(fuzz_command).to include(
      "for attempt in 1 2 3", "Schemathesis contract fuzzing failed",
      "schemathesis==4.6.0", "--constraint .github/schemathesis-constraints.txt",
      "--include-path /inbox/entries/{entry_id}",
      "--include-path /inbox/entries/{entry_id}/chat",
      "--phases examples,fuzzing", "--mode positive",
      'run_schemathesis "$MOBILE_API_READ_TOKEN"',
      'run_schemathesis "$MOBILE_API_MUTATION_TOKEN"',
      "--exclude-operation-id sendChatMessage",
      "--exclude-operation-id resolveChatToolCall"
    )
    expect(fuzz_command).not_to include("--include-method GET")
    expect(Rails.root.join(".github/schemathesis-constraints.txt").read).to eq("hypothesis==6.168.3\n")
  end

  # @spec MOBILE-API-006 MOBILE-API-018
  it "seeds the documented inbox entry example for successful fuzzing" do
    fixture_step = step_run(schemathesis_job, "Create mobile API bearer token")
    pact_fixture_step = step_run(pact_job, "Create mobile API bearer token")

    expect(fixture_step).to include(
      "GithubToken.create!", "Project.create!", "Issue.create!", "ChatSession.create!",
      "id: 4_241", 'paid_state: "needs_input"', "needs_input_questions:",
      "clarifying_question_issue: issue",
      "allowed_github_usernames: [ \"mobile-schema-fuzzer\" ]",
      "MOBILE_API_READ_TOKEN", "MOBILE_API_MUTATION_TOKEN"
    )
    expect(pact_fixture_step).to include('allowed_github_usernames: [ "mobile-contract-verifier" ]')
    expect(openapi_schema.fetch("components").fetch("parameters").fetch("EntryId").fetch("schema")).to include(
      "example" => "clarifying_questions:4241"
    )
  end

  # @spec MOBILE-API-010 MOBILE-API-018
  it "limits conditional polling headers to the strong ETags the API emits" do
    schema = openapi_schema.fetch("components").fetch("parameters").fetch("IfNoneMatch").fetch("schema")

    expect(schema).to include("pattern" => '^"[0-9a-f]{64}"$')
  end

  # @spec MOBILE-API-008 MOBILE-API-018
  it "limits inbox entry IDs to queue IDs that the API can resolve" do
    schema = openapi_schema.fetch("components").fetch("parameters").fetch("EntryId").fetch("schema")

    pattern = schema.fetch("pattern")
    expect(pattern).to include("clarifying_questions", "test_review_pending", "[1-9][0-9]{0,18}$")
    expect(pattern).to include(":")
    expect(pattern).not_to include("%3A")
  end

  # @spec MOBILE-API-006 MOBILE-API-008 MOBILE-API-018
  it "bounds opaque inbox cursors and entry IDs to bigint-backed queue IDs" do
    parameters = openapi_schema.fetch("components").fetch("parameters")

    expect(parameters.fetch("EntryId").fetch("schema")).to include("maxLength" => 40)
    expect(parameters.fetch("InboxCursor").fetch("schema")).to include(
      "maxLength" => 40,
      "pattern" => parameters.fetch("EntryId").fetch("schema").fetch("pattern")
    )
  end

  private

  def contract_jobs
    [ pact_job, schemathesis_job ]
  end

  def pact_job
    workflow.fetch("jobs").fetch("pact-provider-verification")
  end

  def schemathesis_job
    workflow.fetch("jobs").fetch("schemathesis")
  end

  def job_steps(job)
    job.fetch("steps").map { |step| step["name"] }
  end

  def step_run(job, name)
    job.fetch("steps").find { |step| step["name"] == name }.fetch("run")
  end
end
