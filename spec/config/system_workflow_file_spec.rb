# frozen_string_literal: true

require "rails_helper"
require "psych"

class SystemWorkflowFile < Pathname
end

RSpec.describe SystemWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/system_tests.yml"),
      aliases: true
    )
  end

  def system_job
    workflow.fetch("jobs").fetch("system")
  end

  def system_step(name)
    system_job.fetch("steps").find { |step| step["name"] == name }
  end

  # @spec TEST-SUITE-021
  it "does not group system-test runs into a cancellation-prone concurrency queue" do
    expect(workflow).not_to have_key("concurrency")
  end

  # @spec TEST-SUITE-022
  it "allows the hosted browser suite to complete within a bounded job window" do
    expect(system_job.fetch("timeout-minutes")).to eq(180)
  end

  it "passes test credentials to the system job" do
    expect(system_job.fetch("env")).to include(
      "SECRET_KEY_BASE" => "test-secret-key-base",
      "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
      "PAID_TEST_DATABASE" => "paid_test",
      "DATABASE_URL" => "postgres://paid:paid@localhost:5432/paid_test",
      "DB_USERNAME" => "paid",
      "DB_PASSWORD" => "paid"
    )
  end

  it "creates and uses a dedicated non-superuser application role" do
    create_role_step = system_step("Create application database role")

    expect(create_role_step.fetch("run")).to include(
      "ALTER ROLE paid CREATEDB NOSUPERUSER NOBYPASSRLS;"
    )
  end

  # The PGDG signing key download flakes on GitHub runners. Publishing the key
  # without verifying it leaves apt with an unsigned repository, so every later
  # apt-get update fails with "The repository ... is not signed" and takes the
  # whole job down before a single system spec runs.
  # @spec TOOLCHAIN-PIN-028
  it "retries transient PostgreSQL client package setup failures" do
    install_step = system_step("Install PostgreSQL client")
    run = install_step.fetch("run")

    expect(run).to include(
      'for attempt in 1 2 3; do',
      'curl -fsSL --retry 3 --retry-delay 5 --max-time 60',
      'gpg --batch --with-colons --show-keys',
      'B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8',
      'timeout 5m apt-get',
      'apt_with_retry install -y postgresql-client-16'
    )
    expect(run).not_to include("| sudo tee /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc")
    expect(run).to include('sudo rm -f /etc/apt/sources.list.d/pgdg.sources "$keyring"')
  end

  # @spec TOOLCHAIN-PIN-028
  it "uses the runner postgres client when its major version matches" do
    run = system_step("Install PostgreSQL client").fetch("run")

    expect(run).to include(
      "command -v psql",
      "psql --version | grep -Eq '^psql \\(PostgreSQL\\) 16\\.'"
    )
  end

  it "installs a pinned Chrome binary for explicit browser specs" do
    setup_step = system_step("Set up Chrome")
    export_step = system_step("Export Chromium path")

    expect(setup_step).to include("id" => "setup_chrome")
    expect(setup_step.fetch("uses")).to match(/\Abrowser-actions\/setup-chrome@[0-9a-f]{40}\z/)
    expect(export_step.fetch("env")).to include(
      "INSTALLED_CHROME_PATH" => "${{ steps.setup_chrome.outputs.chrome-path }}"
    )
    expect(export_step.fetch("run")).to include('echo "CHROMIUM_PATH=$chrome_path" >> "$GITHUB_ENV"')
  end

  # @spec TEST-SUITE-019
  it "bounds retries for the hosted PostgreSQL empty-result failure" do
    run = system_step("Run system specs").fetch("run")

    expect(run).to include(
      "for attempt in 1 2 3; do",
      "undefined method 'cmd_tuples' for nil",
      "docker ps --filter 'ancestor=postgres:16.15'",
      'docker restart "$postgres_container"',
      'pg_isready -h "$DB_HOST" -U postgres -d postgres',
      'if [ "$attempt" -eq 3 ]; then',
      'sleep "$((attempt * 5))"',
      "exit 1"
    )
  end

  # @spec TOOLCHAIN-PIN-029
  it "installs the Chromium runtime libraries required by Cuprite" do
    runtime_step = system_step("Install Chromium runtime dependencies")
    run = runtime_step.fetch("run")

    expect(run).to include(
      "timeout 5m apt-get",
      "Acquire::http::Timeout=30",
      "Acquire::https::Timeout=30",
      "Acquire::Retries=3",
      "libglib2.0-0t64",
      "libgtk-3-0t64",
      "libnss3",
      "libgbm1",
      "libx11-xcb1"
    )
    expect(run).not_to include("apt-get update")
  end
end
