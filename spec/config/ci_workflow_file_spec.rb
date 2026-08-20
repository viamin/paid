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
    lint_step = workflow.fetch("jobs").fetch("lint").fetch("steps")
      .find { |step| step["name"] == "Verify Postgres image pins and client install sources are in sync" }

    expect(lint_step.fetch("run")).to include('workflow_client="postgresql-client-${major}"')
    expect(lint_step.fetch("run")).to include(
      'check_contains .github/workflows/ci.yml "$workflow_client" ".github/workflows/ci.yml must install $workflow_client"'
    )
    expect(lint_step.fetch("run")).to include(
      'check_contains .github/workflows/ci.yml "apt.postgresql.org/pub/repos/apt" ".github/workflows/ci.yml must install PostgreSQL client tools from PGDG"'
    )
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
