# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::QualityHooks do
  subject(:host) { host_class.new }

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
    example.run
  ensure
    Rails.cache = original_cache
  end

  let(:host_class) do
    Class.new do
      include Containers::QualityHooks
    end
  end

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, open_source: false) }
  let(:user) { project.effective_owner }

  describe "#resolve_mutation_command" do
    before do
      create(
        :pre_commit_requirement,
        :mutation_test,
        account: account,
        project: project,
        name: "mutant",
        command: "bundle exec mutant run --usage commercial --since HEAD~1 --use rspec --jobs 1"
      )
    end

    it "returns the resolved mutation command for ruby projects" do
      expect(
        host.resolve_mutation_command(project, user, "ruby")
      ).to eq("bundle exec mutant run --usage commercial --since HEAD~1 --use rspec --jobs 1")
    end

    it "logs the missing license warning only once per project" do
      original_mutant_license_key = ENV["MUTANT_LICENSE_KEY"]
      ENV["MUTANT_LICENSE_KEY"] = nil
      allow(Rails.logger).to receive(:warn)

      2.times { host.resolve_mutation_command(project, user, "ruby") }

      expect(Rails.logger).to have_received(:warn).once.with(
        hash_including(message: "quality_hooks.mutant_license_missing", project_id: project.id)
      )
    ensure
      ENV["MUTANT_LICENSE_KEY"] = original_mutant_license_key
    end

    it "uses the cache to suppress duplicate warnings across host instances" do
      original_mutant_license_key = ENV["MUTANT_LICENSE_KEY"]
      ENV["MUTANT_LICENSE_KEY"] = nil
      allow(Rails.logger).to receive(:warn)

      host.resolve_mutation_command(project, user, "ruby")
      host_class.new.resolve_mutation_command(project, user, "ruby")

      expect(Rails.logger).to have_received(:warn).once.with(
        hash_including(message: "quality_hooks.mutant_license_missing", project_id: project.id)
      )
    ensure
      ENV["MUTANT_LICENSE_KEY"] = original_mutant_license_key
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
        command: "bundle exec mutant run --usage commercial --since HEAD~1 --use rspec --jobs 4 Foo*"
      )

      expect(
        host.resolve_scheduled_mutation_command(project, user, "ruby")
      ).to eq("bundle exec mutant run --usage commercial --use rspec --jobs 1 Foo\\*")
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
      ).to eq('bundle exec mutant run --include-subject app/models/user\ profile.rb --jobs 1')
    end
  end
end
