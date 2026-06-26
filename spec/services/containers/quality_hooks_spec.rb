# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::QualityHooks do
  subject(:host) { host_class.new }

  let(:host_class) do
    Class.new do
      include Containers::QualityHooks
    end
  end

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:user) { project.effective_owner }

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

    it "returns the resolved mutation command for ruby projects" do
      expect(
        host.resolve_mutation_command(project, user, "ruby")
      ).to eq("bundle exec mutant run --since HEAD~1 --use rspec --jobs 1")
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
      ).to eq("bundle exec mutant run --use rspec --jobs 1 Foo\\*")
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
