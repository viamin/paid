# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::QualityHooks do # @spec QUALITY-LOOPS-003 # @spec QUALITY-LOOPS-004 # @spec QUALITY-LOOPS-005 # @spec POLYGLOT-TEST-003 # @spec POLYGLOT-TEST-011
  subject(:host) { host_class.new }

  let(:host_class) do
    Class.new do
      include Containers::QualityHooks
    end
  end

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:user) { project.effective_owner }

  # Stub the centralized database-availability check the same way the
  # prompts do (#4305, POLYGLOT-TEST-011) so this unit-level spec stays
  # scoped to the hook behavior, not to live service-container provisioning.
  def stub_database_availability(value)
    allow(Prompts::ServiceContainerSections).to receive(:has_database_container?)
      .and_return(value)
  end

  describe "#install_quality_hooks" do
    let(:git_ops) { instance_double(Containers::GitOperations, install_git_hooks: nil) }
    let(:agent_run) { create(:agent_run, project: project) }

    it "disables DB-dependent test and mutation hooks when no database container is running" do
      allow(project).to receive(:test_languages).and_return(%w[ruby])
      stub_database_availability(false)
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1"
      )
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop" ],
        test_command: [],
        mutation_command: "true"
      )
      expect(agent_run.reload.external_metadata.fetch("quality_checks_not_executed")).to contain_exactly(
        hash_including("check" => "test", "reason" => "database_service_unavailable", "status" => "not_executed"),
        hash_including("check" => "mutation", "reason" => "database_service_unavailable", "status" => "not_executed")
      )
    end

    it "keeps test and mutation hooks when a database container is running" do
      allow(project).to receive(:detected_language).and_return("ruby")
      stub_database_availability(true)
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1"
      )
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop" ],
        test_command: [ "bundle exec rspec" ],
        mutation_command: "RAILS_ENV=test bundle exec mutant run --since HEAD\\~1 --use rspec --jobs 1 --results-dir .mutant/results"
      )
    end

    it "keeps test hooks for non-DB-dependent languages without a database" do
      allow(project).to receive(:detected_language).and_return("go")
      stub_database_availability(false)
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "golangci-lint run" ],
        test_command: [ "go test ./..." ],
        mutation_command: "true"
      )
    end

    it "gates Elixir/Phoenix test hooks the same as Ruby when no database is running" do
      allow(project).to receive(:detected_language).and_return("elixir")
      stub_database_availability(false)
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "mix credo --strict" ],
        test_command: [],
        mutation_command: "true"
      )
      expect(agent_run.reload.external_metadata.fetch("quality_checks_not_executed")).to contain_exactly(
        hash_including("check" => "test", "language" => "elixir", "reason" => "database_service_unavailable", "status" => "not_executed")
      )
    end

    it "runs each language's commands for a polyglot repo with a database" do
      project.update!(repo_profile: { "test_languages" => [ "ruby", "elixir" ] })
      stub_database_availability(true)
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1"
      )
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop", "mix credo --strict" ],
        test_command: [ "bundle exec rspec", "mix test" ],
        mutation_command: "RAILS_ENV=test bundle exec mutant run --since HEAD\\~1 --use rspec --jobs 1 --results-dir .mutant/results"
      )
    end

    it "gates only DB-dependent languages for a polyglot repo without a database" do
      project.update!(repo_profile: { "test_languages" => [ "ruby", "go" ] })
      stub_database_availability(false)
      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop", "golangci-lint run" ],
        test_command: [ "go test ./..." ],
        mutation_command: "true"
      )
    end

    it "keeps non-db test commands when the repo profile is polyglot" do # @spec POLYGLOT-TEST-003
      project.update!(repo_profile: { "test_languages" => %w[elixir javascript] })
      stub_database_availability(false)

      host.install_quality_hooks(git_ops, agent_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "mix credo --strict", "npm run lint" ],
        test_command: [ "npm test" ],
        mutation_command: "true"
      )
    end

    # @spec TDD-GUARD-009 # @spec TDD-GUARD-010
    it "suppresses the mutation command during a test_writing phase run even when mutation testing is configured" do
      allow(project).to receive(:detected_language).and_return("ruby")
      stub_database_availability(true)
      create(:pre_commit_requirement, :mutation_test, account:, project:, name: "mutant", command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1")
      test_writing_run = create(:agent_run, project: project, tdd_phase: "test_writing")

      host.install_quality_hooks(git_ops, test_writing_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop" ],
        test_command: [ "bundle exec rspec" ],
        mutation_command: "true",
        test_failure_behavior: :permit,
        pre_commit_guard: a_string_including("tdd_phase=\"test_writing\"")
      )
    end

    # @spec TDD-GUARD-009
    it "keeps the mutation command during a test_fixing phase run" do
      allow(project).to receive(:detected_language).and_return("ruby")
      stub_database_availability(true)
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1"
      )
      test_fixing_run = create(:agent_run, project: project, tdd_phase: "test_fixing")

      host.install_quality_hooks(git_ops, test_fixing_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop" ],
        test_command: [ "bundle exec rspec" ],
        mutation_command: "RAILS_ENV=test bundle exec mutant run --since HEAD\\~1 --use rspec --jobs 1 --results-dir .mutant/results",
        pre_commit_guard: a_string_including("tdd_phase=\"test_fixing\"")
      )
    end

    it "installs a frozen-test write guard during a refactor phase run" do
      allow(project).to receive(:detected_language).and_return("ruby")
      stub_database_availability(true)
      refactor_run = create(:agent_run, project: project, tdd_phase: "refactor")

      host.install_quality_hooks(git_ops, refactor_run)

      expect(git_ops).to have_received(:install_git_hooks).with(
        lint_command: [ "bundle exec rubocop" ],
        test_command: [ "bundle exec rspec" ],
        mutation_command: "true",
        pre_commit_guard: a_string_including("tdd_phase=\"refactor\"")
      )
    end

    # @spec POLYGLOT-TEST-011 — the hook reads the same database-availability
    # signal the prompt uses, so the unit under test (#4305).
    it "queries the same database-availability helper the prompt uses" do
      allow(project).to receive_messages(
        detected_language: "ruby",
        test_languages: %w[ruby]
      )
      stubbed = false
      allow(Prompts::ServiceContainerSections).to receive(:has_database_container?) do
        stubbed = true
        false
      end
      host.install_quality_hooks(git_ops, agent_run)

      expect(stubbed).to be(true)
    end
  end

  describe "#resolve_mutation_command" do
    before do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1"
      )
    end

    it "returns the resolved mutation command with results dir injected" do
      expect(
        host.resolve_mutation_command(project, user, "ruby")
      ).to eq("RAILS_ENV=test bundle exec mutant run --since HEAD\\~1 --use rspec --jobs 1 --results-dir .mutant/results")
    end
  end

  describe "#resolve_scheduled_mutation_command" do
    it "removes incremental mode and keeps jobs pinned to one worker" do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 4 Foo*"
      )

      expect(
        host.resolve_scheduled_mutation_command(project, user, "ruby")
      ).to eq("RAILS_ENV=test bundle exec mutant run --use rspec --jobs 1 Foo\\* --results-dir .mutant/results")
    end

    it "preserves shell escaping for quoted arguments" do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: 'bundle exec mutant run --since HEAD~1 --include-subject "app/models/user profile.rb"'
      )

      expect(
        host.resolve_scheduled_mutation_command(project, user, "ruby")
      ).to eq('RAILS_ENV=test bundle exec mutant run --include-subject app/models/user\ profile.rb --jobs 1 --results-dir .mutant/results')
    end

    it "strips existing --results-dir and replaces with canonical path" do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --results-dir /custom/path --use rspec"
      )

      expect(
        host.resolve_scheduled_mutation_command(project, user, "ruby")
      ).to eq("RAILS_ENV=test bundle exec mutant run --use rspec --jobs 1 --results-dir .mutant/results")
    end

    it "strips existing equals-form --results-dir=value and replaces with canonical path" do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --results-dir=/custom/path --use rspec"
      )

      expect(
        host.resolve_scheduled_mutation_command(project, user, "ruby")
      ).to eq("RAILS_ENV=test bundle exec mutant run --use rspec --jobs 1 --results-dir .mutant/results")
    end
  end
end
