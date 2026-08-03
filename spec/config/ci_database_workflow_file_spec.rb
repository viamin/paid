# frozen_string_literal: true

require "rails_helper"
require "psych"

class CiDatabaseWorkflowFile < Pathname
end

RSpec.describe CiDatabaseWorkflowFile, :no_db do
  workflow_expectations = {
    ".github/workflows/ci.yml" => {
      "test" => {
        "db_username" => "paid",
        "db_password" => "paid",
        "creates_application_role" => true,
        "database_setup_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate",
        "bootstrap_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails ci:bootstrap_test_defaults"
      },
      "performance" => {
        "db_username" => "paid",
        "db_password" => "paid",
        "creates_application_role" => true,
        "database_setup_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate",
        "bootstrap_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails ci:bootstrap_test_defaults"
      }
    },
    ".github/workflows/system_tests.yml" => {
      "system" => {
        "db_username" => "paid",
        "db_password" => "paid",
        "creates_application_role" => true,
        "uses_database_url" => true,
        "asset_build_command" => [
          "env -u DATABASE_URL -u CABLE_DATABASE_URL yarn build",
          "env -u DATABASE_URL -u CABLE_DATABASE_URL yarn build:css"
        ],
        "database_setup_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate",
        "bootstrap_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails ci:bootstrap_test_defaults",
        "test_command_snippets" => [ "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rspec spec/system" ]
      }
    },
    ".github/workflows/pr-screenshots.yml" => {
        "capture" => {
          "db_username" => "paid",
          "db_password" => "paid",
          "creates_application_role" => true,
          "uses_database_url" => true,
          "database_setup_command" => "bin/rails db:create db:schema:load",
          "bootstrap_command" => "bin/rails ci:bootstrap_test_defaults"
        }
      },
    ".github/workflows/test_prof.yml" => {
        "profile" => {
          "db_username" => "paid",
          "db_password" => "paid",
          "creates_application_role" => true,
          "database_setup_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate",
          "bootstrap_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails ci:bootstrap_test_defaults",
          "test_command_snippets" => [
            "env -u DATABASE_URL -u CABLE_DATABASE_URL FPROF=1 bin/rspec",
            "env -u DATABASE_URL -u CABLE_DATABASE_URL FDOC=1 bin/rspec"
          ]
        }
      },
    ".github/workflows/ephemeral_tests.yml" => {
        "run-tests" => {
          "db_username" => "paid",
          "db_password" => "paid",
          "creates_application_role" => true,
          "asset_build_command" => [
            "env -u DATABASE_URL -u CABLE_DATABASE_URL yarn build",
            "env -u DATABASE_URL -u CABLE_DATABASE_URL yarn build:css"
          ],
          "database_setup_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate",
          "bootstrap_command" => "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails ci:bootstrap_test_defaults",
          "test_command_snippets" => [ "env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rspec $spec_files" ]
        }
      }
  }.freeze

  workflow_expectations.each do |workflow_path, jobs|
    context workflow_path do
      subject(:workflow) { Psych.safe_load_file(Rails.root.join(workflow_path), aliases: true) }

      def expect_application_role_database_url!(job, expectations)
        return unless expectations.fetch("creates_application_role")

        if expectations.fetch("uses_database_url", false)
          expect(job.fetch("env")).to include(
            "DATABASE_URL" => "postgres://paid:paid@localhost:5432/paid_test"
          )
          expect(job.fetch("env")).not_to have_key("CABLE_DATABASE_URL")
        else
          expect(job.fetch("env")).not_to have_key("DATABASE_URL")
          expect(job.fetch("env")).not_to have_key("CABLE_DATABASE_URL")
        end
      end

      def expect_database_yml_connection!(job, expectations)
        return if expectations.fetch("uses_database_url", false)

        expect(job.fetch("env")).not_to have_key("DATABASE_URL")
        expect(job.fetch("env")).not_to have_key("CABLE_DATABASE_URL")
      end

      jobs.each do |job_name, expectations|
        it "uses the expected database connection flow for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          step_names = job.fetch("steps").map { |step| step["name"] }

          expect(job.fetch("env")).to include(
            "PAID_TEST_DATABASE" => "paid_test",
            "DB_USERNAME" => expectations.fetch("db_username"),
            "DB_PASSWORD" => expectations.fetch("db_password"),
            "TMPDIR" => "${{ github.workspace }}/.tmp-build",
            "YARN_CACHE_FOLDER" => "${{ github.workspace }}/.cache-yarn",
            "XDG_CACHE_HOME" => "${{ github.workspace }}/.cache",
            "npm_config_cache" => "${{ github.workspace }}/.cache/npm",
            "PLAYWRIGHT_BROWSERS_PATH" => "${{ github.workspace }}/.cache/ms-playwright"
          )

          expect_application_role_database_url!(job, expectations)
          expect_database_yml_connection!(job, expectations)

          if expectations.fetch("creates_application_role")
            expect(step_names).to include("Create application database role")
          else
            expect(step_names).not_to include("Create application database role")
          end
        end

        it "installs the PGDG postgres client major package for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          install_step = job.fetch("steps").find { |step| step["name"] == "Install PostgreSQL client" }

          expect(install_step.fetch("run")).to include("apt.postgresql.org/pub/repos/apt")
          expect(install_step.fetch("run")).to include("postgresql-client-16")
        end

        it "installs JavaScript dependencies with workspace-backed temp and cache directories for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          install_step = job.fetch("steps").find { |step| step["name"] == "Install JavaScript dependencies" }

          expect(install_step.fetch("run")).to include('mkdir -p "$TMPDIR" "$YARN_CACHE_FOLDER" "$XDG_CACHE_HOME"')
          expect(install_step.fetch("run")).to include("yarn install --frozen-lockfile && bin/yarn-postinstall")
        end

        it "creates workspace-backed temp and cache directories before tool setup for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          steps = job.fetch("steps")
          prepare_index = steps.index { |step| step["name"] == "Prepare workspace cache directories" }
          ruby_index = steps.index { |step| step["name"] == "Set up Ruby" }
          node_index = steps.index { |step| step["name"] == "Set up Node" }

          expect(prepare_index).not_to be_nil
          expect(steps.fetch(prepare_index).fetch("run")).to eq(
            'mkdir -p "$TMPDIR" "$YARN_CACHE_FOLDER" "$XDG_CACHE_HOME" "$npm_config_cache" "$PLAYWRIGHT_BROWSERS_PATH"'
          )
          expect(prepare_index).to be < ruby_index
          expect(prepare_index).to be < node_index
        end

        it "uses the expected database bootstrap command for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          setup_step = job.fetch("steps").find { |step| step["name"] == "Set up database" }

          expect(setup_step.fetch("run")).to eq(expectations.fetch("database_setup_command"))
        end

        it "bootstraps required orchestration defaults after database setup for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          bootstrap_step = job.fetch("steps").find { |step| step["name"] == "Bootstrap test defaults" }

          expect(bootstrap_step.fetch("run")).to eq(expectations.fetch("bootstrap_command"))
        end

        it "avoids inherited database urls when building assets or running tests for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)

          if expectations.key?("asset_build_command")
            build_step = job.fetch("steps").find { |step| step["name"] == "Build assets" }

            expect(build_step.fetch("run")).to include(*expectations.fetch("asset_build_command"))
          end

          next unless expectations.key?("test_command_snippets")

          test_step = job.fetch("steps").find do |step|
            step["name"]&.start_with?("Run ")
          end

          expect(test_step.fetch("run")).to include(*expectations.fetch("test_command_snippets"))
        end
      end

      if workflow_path == ".github/workflows/ci.yml"
        it "replays migrations in a dedicated CI job" do
          job = workflow.fetch("jobs").fetch("migrations")
          setup_step = job.fetch("steps").find { |step| step["name"] == "Replay migrations" }

          expect(setup_step).not_to be_nil, "expected migrations job to include a Replay migrations step"
          expect(job.fetch("env")).to include(
            "PAID_TEST_DATABASE" => "paid_test",
            "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
            "DB_USERNAME" => "postgres",
            "DB_PASSWORD" => "postgres"
          )
          expect(setup_step.fetch("run")).to eq("env -u DATABASE_URL -u CABLE_DATABASE_URL bin/rails db:create db:migrate")
        end
      end
    end
  end
end
