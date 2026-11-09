# frozen_string_literal: true

require "rails_helper"
require "psych"

class MutationWorkflowFile < Pathname
end

RSpec.describe MutationWorkflowFile, :no_db do
  subject(:workflow) { Psych.safe_load_file(Rails.root.join(".github/workflows/mutation.yml"), aliases: true) }

  # @spec POSTGRESQL-PERSISTENCE-002
  it "uses a restricted application role before preparing each mutation database" do
    expect(workflow.fetch("env")).to include(
      "DATABASE_URL" => "postgres://paid:paid@localhost:5432/paid_test",
      "DB_USERNAME" => "paid",
      "DB_PASSWORD" => "paid"
    )

    %w[incremental full].each do |job_name|
      steps = workflow.fetch("jobs").fetch(job_name).fetch("steps")
      client_install_index = steps.index { |step| step["name"] == "Install PostgreSQL client" }
      role_creation_index = steps.index { |step| step["name"] == "Create application database role" }
      database_prepare_index = steps.index { |step| step["name"] == "Prepare database" }

      expect(client_install_index).to be < role_creation_index
      expect(role_creation_index).to be < database_prepare_index
      expect(steps.fetch(role_creation_index).fetch("run")).to include("ALTER ROLE paid CREATEDB CREATEROLE NOSUPERUSER NOBYPASSRLS;")
    end
  end
end
