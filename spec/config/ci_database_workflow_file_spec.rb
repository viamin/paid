# frozen_string_literal: true

require "rails_helper"
require "psych"

class CiDatabaseWorkflowFile < Pathname
end

RSpec.describe CiDatabaseWorkflowFile, :no_db do
  workflow_expectations = {
    ".github/workflows/ci.yml" => {
      "test" => true,
      "performance" => true
    },
    ".github/workflows/system_tests.yml" => {
      "system" => true
    },
    ".github/workflows/pr-screenshots.yml" => {
      "capture" => true
    },
    ".github/workflows/test_prof.yml" => {
      "profile" => true
    },
    ".github/workflows/ephemeral_tests.yml" => {
      "run-tests" => true
    }
  }.freeze

  workflow_expectations.each do |workflow_path, jobs|
    context workflow_path do
      subject(:workflow) { Psych.safe_load_file(Rails.root.join(workflow_path), aliases: true) }

      jobs.each_key do |job_name|
        it "uses the expected database bootstrap role flow for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          step_names = job.fetch("steps").map { |step| step["name"] }

          expect(job.fetch("env")).to include(
            "PAID_TEST_DATABASE" => "paid_test",
            "DB_USERNAME" => "paid",
            "DB_PASSWORD" => "paid",
            "TMPDIR" => "${{ github.workspace }}/.tmp-build",
            "YARN_CACHE_FOLDER" => "${{ github.workspace }}/.cache-yarn"
          )
          expect(step_names).to include("Create application database role")
        end

        it "installs the exact PGDG postgres client package for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          install_step = job.fetch("steps").find { |step| step["name"] == "Install PostgreSQL client" }

          expect(install_step.fetch("run")).to include("apt.postgresql.org/pub/repos/apt")
          expect(install_step.fetch("run")).to include("postgresql-client-16=16.13-1.pgdg24.04+1")
        end

        it "installs JavaScript dependencies with workspace-backed temp and cache directories for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          install_step = job.fetch("steps").find { |step| step["name"] == "Install JavaScript dependencies" }

          expect(install_step.fetch("run")).to include('mkdir -p "$TMPDIR" "$YARN_CACHE_FOLDER"')
          expect(install_step.fetch("run")).to include("yarn install --frozen-lockfile && bin/yarn-postinstall")
        end
      end
    end
  end
end
