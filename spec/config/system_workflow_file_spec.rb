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

  # @spec MOBILE-API-016
  it "allows the browser suite to install the mobile contract toolchain from a cold cache" do
    expect(system_job.fetch("timeout-minutes")).to eq(60)
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
      'grep -q "BEGIN PGP PUBLIC KEY BLOCK"',
      'timeout 5m apt-get',
      'apt_with_retry install -y postgresql-client-16'
    )
    expect(run).not_to include("| sudo tee /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc")
    expect(run).to include('sudo rm -f /etc/apt/sources.list.d/pgdg.sources "$keyring"')
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
end
