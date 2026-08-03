# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Notifications::RuleAdapter do
  let(:account) { create(:account) }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe ".for" do
    it "returns an anonymous rule subclass bound to the check class" do
      rule = described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)

      expect(rule.superclass).to eq(described_class)
      expect(rule.check_class).to eq(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
    end
  end

  describe "#source" do
    it "derives the source from the check code" do
      rule = described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)

      expect(rule.new.send(:source)).to eq("health_check_auto_merge_without_owner")
    end
  end

  describe "#detect" do
    it "returns projects where a project-scope check fires" do
      matching = create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)
      healthy = create(:project, account: account, auto_merge_mode: "off")
      create(:project, auto_merge_mode: "all", owner_reviewer_login: nil) # other account

      rule = described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
      matches = rule.new.send(:detect, account)

      expect(matches).to include(matching)
      expect(matches).not_to include(healthy)
      expect(matches.size).to eq(1)
    end

    it "returns projects where a user-scope check fires via effective_owner" do
      owner = create(:user, account: account)
      # Disable the auto-created default runner so NoAgentRunners fires.
      owner.runners.update_all(enabled_for_agent_runs: false)
      matching = create(:project, account: account, created_by: owner)

      healthy_owner = create(:user, account: account)
      healthy = create(:project, account: account, created_by: healthy_owner)

      rule = described_class.for(HealthChecks::Checks::User::NoAgentRunners)
      matches = rule.new.send(:detect, account)

      expect(matches).to include(matching)
      expect(matches).not_to include(healthy)
    end

    it "returns projects where a runner-scope check fires via effective_owner" do
      owner = create(:user, account: account)
      project = create(:project, account: account, created_by: owner)

      # Use a rule adapter with a custom check_class that always fires on runners.
      stub_check = Class.new(HealthChecks::Check) do
        self.scope = :runner

        def call
          finding(severity: :error, title: "Stub", description: "stub")
        end
      end
      stub_check.define_singleton_method(:code) { :stub_runner_check }
      stub_check.define_singleton_method(:name) { "StubRunnerCheck" }

      rule = described_class.for(stub_check)
      matches = rule.new.send(:detect, account)

      expect(matches).to include(project)
    end
  end

  describe "#build" do
    it "returns notification attrs from the first finding" do
      project = create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)

      rule = described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
      attrs = rule.new.send(:build, project)

      expect(attrs[:severity]).to eq(:error)
      expect(attrs[:title]).to eq("Auto-merge enabled without an owner reviewer")
      expect(attrs[:description]).to include("Auto-merge")
      expect(attrs[:nav_section]).to eq("projects")
      expect(attrs[:action_url]).to be_present
      expect(attrs[:metadata]).to be_a(Hash)
    end

    it "raises when no finding exists for the project" do
      project = create(:project, account: account, auto_merge_mode: "off")

      rule = described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)

      expect { rule.new.send(:build, project) }.to raise_error(/no finding/)
    end
  end

  describe "#call (publish + auto-resolve)" do
    let(:check_class) { HealthChecks::Checks::Project::AutoMergeWithoutOwner }
    let(:source) { "health_check_auto_merge_without_owner" }

    it "publishes a notification for a project where the check fires" do
      matching = create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)

      rule = described_class.for(check_class)

      expect {
        rule.call(scope: account)
      }.to change(Notification, :count).by(1)

      notification = Notification.find_by!(account: account, source: source, subject: matching)
      expect(notification.severity).to eq("error")
      expect(notification.nav_section).to eq("projects")
      expect(notification.resolved_at).to be_nil
    end

    it "auto-resolves a notification for a project that becomes healthy" do
      cleared = create(:project, account: account, auto_merge_mode: "off")
      create(:notification, account: account, source: source, subject: cleared)

      rule = described_class.for(check_class)

      expect {
        rule.call(scope: account)
      }.not_to change(Notification, :count)

      notification = Notification.find_by!(account: account, source: source, subject: cleared)
      expect(notification.resolved_at).to be_present
    end

    it "updates an existing notification rather than creating a duplicate" do
      project = create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)

      rule = described_class.for(check_class)

      2.times { rule.call(scope: account) }

      expect(Notification.where(source: source, subject: project).count).to eq(1)
    end

    it "does not publish for a fully healthy account" do
      create(:project, account: account, auto_merge_mode: "off")

      rule = described_class.for(check_class)

      expect {
        rule.call(scope: account)
      }.not_to change(Notification, :count)
    end

    it "handles multiple projects in the same account" do
      bad = create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)
      create(:project, account: account, auto_merge_mode: "off")

      rule = described_class.for(check_class)

      expect {
        rule.call(scope: account)
      }.to change(Notification, :count).by(1)

      expect(Notification.find_by!(subject: bad).resolved_at).to be_nil
    end
  end

  describe ".evaluate_all integration" do
    before do
      Notifications::Rule.register(
        described_class.for(HealthChecks::Checks::Project::AutoMergeWithoutOwner)
      )
    end

    after do
      Notifications::Rule.rule_classes.clear
    end

    it "publishes notifications for all registered rules" do
      create(:project, account: account, auto_merge_mode: "all", owner_reviewer_login: nil)

      expect {
        Notifications::Rule.evaluate_all(account: account)
      }.to change(Notification, :count).by(1)
    end
  end
end
