# frozen_string_literal: true

require "rails_helper"
require "psych"

class CiWorkflowFile < Pathname
end

RSpec.describe CiWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/ci.yml"),
      aliases: true
    )
  end

  let(:postgres_pin_step) do
    workflow.fetch("jobs").fetch("lint").fetch("steps")
      .find { |step| step["name"] == "Verify Postgres image pins and client install sources are in sync" }
  end

  it "passes the expected test credentials to the database-backed ci jobs" do
    jobs = workflow.fetch("jobs")

    expect(jobs.fetch("test").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_TEST_DATABASE" => "paid_test"
    )
    expect(jobs.fetch("performance").fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
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
    install_step = workflow.fetch("jobs").fetch("test").fetch("steps")
      .find { |step| step["name"] == "Install ast-grep" }

    expect(install_step.fetch("run")).to include('mkdir -p "$HOME/.local/bin"')
    expect(install_step.fetch("run")).to include('echo "$HOME/.local/bin" >> "$GITHUB_PATH"')
    expect(install_step.fetch("run")).to include('INSTALL_DIR="$HOME/.local/bin" bin/install-ast-grep')
  end

  it "fetches full git history for the test job checkout" do
    checkout_step = workflow.fetch("jobs").fetch("test").fetch("steps")
      .find { |step| step["name"] == "Checkout code" }

    expect(checkout_step.fetch("with")).to include(
      "fetch-depth" => 0,
      "persist-credentials" => false
    )
  end
end
