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
        it "keeps #{job_name} on the bootstrap postgres role until db:prepare completes" do
          job = workflow.fetch("jobs").fetch(job_name)

          expect(job.fetch("env")).to include(
            "DB_USERNAME" => "postgres",
            "DB_PASSWORD" => "postgres"
          )

          step_names = job.fetch("steps").map { |step| step["name"] }
          expect(step_names).not_to include("Create application database role")
        end

        it "installs the PGDG postgres client by major version for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          install_step = job.fetch("steps").find { |step| step["name"] == "Install PostgreSQL client" }

          expect(install_step.fetch("run")).to include("apt.postgresql.org/pub/repos/apt")
          expect(install_step.fetch("run")).to include("postgresql-client-16")
          expect(install_step.fetch("run")).not_to include("postgresql-client-16=")
        end
      end
    end
  end
end
