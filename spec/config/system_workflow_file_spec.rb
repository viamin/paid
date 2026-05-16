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
      "PAID_TEST_DATABASE" => "paid_test"
    )
  end

  it "locates Chromium from PATH and exports the chosen binary" do
    locate_step = system_step("Locate Chromium-family browser")
    export_step = system_step("Export Chromium path")

    expect(locate_step.fetch("id")).to eq("locate_chromium")
    expect(locate_step.fetch("run")).to include("command -v chromium || true")
    expect(locate_step.fetch("run")).to include('echo "chrome_path=$chrome_path" >> "$GITHUB_OUTPUT"')
    expect(export_step.fetch("env")).to include(
      "LOCATED_CHROME_PATH" => "${{ steps.locate_chromium.outputs.chrome_path }}",
      "INSTALLED_CHROME_PATH" => "${{ steps.setup_chrome.outputs.chrome-path }}"
    )
    expect(export_step.fetch("run")).to include('echo "CHROMIUM_PATH=$chrome_path" >> "$GITHUB_ENV"')
  end

  it "installs a fallback Chrome binary when PATH discovery misses" do
    expect(system_step("Set up Chrome fallback")).to include(
      "id" => "setup_chrome",
      "if" => "steps.locate_chromium.outputs.chrome_path == ''",
      "uses" => "browser-actions/setup-chrome@v1"
    )
  end

  it "fails loudly if no Chromium binary is available after fallback installation" do
    export_step = system_step("Export Chromium path")

    expect(export_step.fetch("run")).to include("No Chrome/Chromium binary found after fallback installation")
  end
end
