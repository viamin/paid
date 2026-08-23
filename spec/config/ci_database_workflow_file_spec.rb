# frozen_string_literal: true

require "rails_helper"
require "psych"

class CiDatabaseWorkflowFile < Pathname
end

RSpec.describe CiDatabaseWorkflowFile, :no_db do
  workflow_expectations = {
    ".github/workflows/ci.yml" => {
      "test" => {
        "db_username" => "postgres",
        "db_password" => "postgres",
        "creates_application_role" => false
      },
      "performance" => {
        "db_username" => "postgres",
        "db_password" => "postgres",
        "creates_application_role" => false
      }
    },
    ".github/workflows/system_tests.yml" => {
      "system" => {
        "db_username" => "paid",
        "db_password" => "paid",
        "creates_application_role" => true
      }
    },
    ".github/workflows/pr-screenshots.yml" => {
      "capture" => {
        "db_username" => "paid",
        "db_password" => "paid",
        "creates_application_role" => true
      }
    },
    ".github/workflows/test_prof.yml" => {
      "profile" => {
        "db_username" => "postgres",
        "db_password" => "postgres",
        "creates_application_role" => false
      }
    },
    ".github/workflows/ephemeral_tests.yml" => {
      "run-tests" => {
        "db_username" => "postgres",
        "db_password" => "postgres",
        "creates_application_role" => false
      }
    }
  }.freeze

  workflow_expectations.each do |workflow_path, jobs|
    context workflow_path do
      subject(:workflow) { Psych.safe_load_file(Rails.root.join(workflow_path), aliases: true) }

      def expected_test_database_env(expectations)
        {
          "PAID_DEVELOPMENT_DATABASE" => "paid_test",
          "PAID_DEVELOPMENT_CABLE_DATABASE" => "paid_test",
          "PAID_TEST_DATABASE" => "paid_test",
          "PGHOST" => "localhost",
          "PGPORT" => 5432,
          "PGUSER" => expectations.fetch("db_username"),
          "PGPASSWORD" => expectations.fetch("db_password"),
          "DB_USERNAME" => expectations.fetch("db_username"),
          "DB_PASSWORD" => expectations.fetch("db_password"),
          "TMPDIR" => "${{ github.workspace }}/.tmp-build",
          "YARN_CACHE_FOLDER" => "${{ github.workspace }}/.cache-yarn",
          "XDG_CACHE_HOME" => "${{ github.workspace }}/.cache",
          "npm_config_cache" => "${{ github.workspace }}/.cache/npm",
          "PLAYWRIGHT_BROWSERS_PATH" => "${{ github.workspace }}/.cache/ms-playwright"
        }
      end

      def expect_application_role_database_url!(job, expectations)
        return unless expectations.fetch("creates_application_role")

        expect(job.fetch("env")).to include(
          "DATABASE_URL" => "postgres://paid:paid@localhost:5432/paid_test"
        )
      end

      def expect_database_yml_connection!(job, expectations)
        return if expectations.fetch("creates_application_role")

        expect(job.fetch("env")).not_to have_key("DATABASE_URL")
        expect(job.fetch("env")).not_to have_key("CABLE_DATABASE_URL")
      end

      jobs.each do |job_name, expectations|
        it "uses the expected database connection flow for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          step_names = job.fetch("steps").map { |step| step["name"] }

          expect(job.fetch("env")).to include(expected_test_database_env(expectations))

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

        it "bootstraps a schema-only test database for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          setup_step = job.fetch("steps").find { |step| step["name"] == "Set up database" }

          expect(setup_step.fetch("run")).to eq("bin/rails db:create db:schema:load")
        end

        it "bootstraps required orchestration defaults after schema load for #{job_name}" do
          job = workflow.fetch("jobs").fetch(job_name)
          bootstrap_step = job.fetch("steps").find { |step| step["name"] == "Bootstrap test defaults" }

          expect(bootstrap_step.fetch("run")).to eq("bin/rails ci:bootstrap_test_defaults")
        end
      end

      if workflow_path == ".github/workflows/ci.yml"
        # @spec POSTGRESQL-PERSISTENCE-007
        it "replays this branch's migrations against the base schema in a dedicated CI job" do
          job = workflow.fetch("jobs").fetch("migrations")
          replay_step = job.fetch("steps").find { |step| step["name"] == "Replay migrations added on this branch" }

          expect(replay_step).not_to be_nil,
            "expected migrations job to include a 'Replay migrations added on this branch' step"
          expect(job.fetch("env")).to include(
            "PAID_DEVELOPMENT_DATABASE" => "paid_test",
            "PAID_DEVELOPMENT_CABLE_DATABASE" => "paid_test",
            "PAID_TEST_DATABASE" => "paid_test",
            "RAILS_TEST_KEY" => "${{ secrets.RAILS_TEST_KEY }}",
            "PGHOST" => "localhost",
            "PGPORT" => 5432,
            "PGUSER" => "postgres",
            "PGPASSWORD" => "postgres",
            "DB_USERNAME" => "postgres",
            "DB_PASSWORD" => "postgres"
          )
          # bin/ci-migration-replay loads the base revision's db/schema.rb so only
          # this branch's migrations remain pending, runs them for real, and
          # verifies the resulting dump matches the committed schema.
          expect(replay_step.fetch("run")).to eq("bin/ci-migration-replay HEAD^")

          checkout_step = job.fetch("steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
          expect(checkout_step.fetch("with").fetch("fetch-depth")).to eq(2),
            "bin/ci-migration-replay needs HEAD^ available, so checkout must fetch at least depth 2"
        end
      end
    end
  end
end
