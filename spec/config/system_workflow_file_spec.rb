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

  it "installs a known-good Chrome binary for explicit browser specs" do
    setup_step = system_step("Set up Chrome")
    export_step = system_step("Export Chromium path")

    expect(setup_step).to include(
      "id" => "setup_chrome",
      "uses" => "browser-actions/setup-chrome@2e1d749697dd1612b833dba4a722266286fbefcd"
    )
    expect(export_step.fetch("env")).to include(
      "INSTALLED_CHROME_PATH" => "${{ steps.setup_chrome.outputs.chrome-path }}"
    )
    expect(export_step.fetch("run")).to include('echo "CHROMIUM_PATH=$chrome_path" >> "$GITHUB_ENV"')
  end
end
