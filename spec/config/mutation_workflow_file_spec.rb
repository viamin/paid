# frozen_string_literal: true

require "rails_helper"
require "psych"

class MutationWorkflowFile < Pathname
end

RSpec.describe MutationWorkflowFile, :no_db do
  subject(:workflow) { Psych.safe_load_file(Rails.root.join(".github/workflows/mutation.yml"), aliases: true) }

  # @spec MUTATION-CI-001 MUTATION-CI-002
  it "filters incremental runs while retaining the daily full sweep" do
    events = workflow.fetch(true)
    expect(events.fetch("pull_request").fetch("paths")).to include(
      "app/services/tenant_context.rb", "app/services/prompts/build_for_issue.rb",
      "app/services/prompts/build_for_pr.rb", "app/policies/application_policy.rb",
      "app/policies/operator_console/base_policy.rb", "spec/services/tenant_context_spec.rb",
      "spec/services/prompts/build_for_issue_spec.rb", "spec/services/prompts/build_for_pr_spec.rb",
      "spec/policies/application_policy_spec.rb", "spec/policies/operator_console/base_policy_spec.rb",
      "spec/support/**", "spec/factories/**", "spec/fixtures/**", "spec/spec_helper.rb",
      "spec/rails_helper.rb", "config/**", "lib/**", "db/**", "Gemfile", "Gemfile.lock",
      ".mutant.yml", ".tool-versions", ".rspec", ".simplecov", "bin/rspec", "bin/rails", "Rakefile", "config.ru",
      ".github/workflows/mutation.yml"
    )
    expect(events.fetch("schedule")).to eq([ { "cron" => "17 9 * * *" } ])
    expect(workflow.fetch("jobs").fetch("full").fetch("if")).to eq("github.event_name == 'schedule'")
  end

  # @spec MUTATION-CI-003
  it "requires path-filter review when the configured subject classes change" do
    config = Psych.safe_load_file(Rails.root.join(".mutant.yml"))
    classes = config.fetch("matcher").fetch("subjects").map { |subject| subject.split(/[.#]/).first }.uniq
    expect(classes.sort).to eq(%w[
      ApplicationPolicy ApplicationPolicy::Scope OperatorConsole::BasePolicy
      OperatorConsole::BasePolicy::Scope Prompts::BuildForIssue Prompts::BuildForPr TenantContext
    ].sort)
  end

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
