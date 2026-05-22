# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe Rake::Task do
  let(:test_flag) { :test_feature_flag }
  let(:test_definition) do
    FeatureFlags::Definition.new(
      name: :test_feature_flag,
      owner: "test",
      intent: "Test flag",
      rollout_plan: "None",
      cleanup_criteria: "None"
    )
  end
  let(:enable_task) { described_class["feature_flags:enable"] }
  let(:disable_task) { described_class["feature_flags:disable"] }
  let(:enable_percentage_of_actors_task) { described_class["feature_flags:enable_percentage_of_actors"] }
  let(:enable_percentage_of_time_task) { described_class["feature_flags:enable_percentage_of_time"] }
  let(:list_task) { described_class["feature_flags:list"] }
  let(:status_task) { described_class["feature_flags:status"] }

  around do |example|
    original_project = ENV["PROJECT"]
    original_project_id = ENV["PROJECT_ID"]

    example.run
  ensure
    ENV["PROJECT"] = original_project
    ENV["PROJECT_ID"] = original_project_id
  end

  around { |example| SilenceStreams.call(:stdout) { example.run } }

  before do
    Rails.application.load_tasks unless described_class.task_defined?("feature_flags:list")
    enable_task.reenable
    disable_task.reenable
    enable_percentage_of_actors_task.reenable
    enable_percentage_of_time_task.reenable
    list_task.reenable
    status_task.reenable
    FeatureFlags.flipper.features.each(&:remove)
    stub_const("#{FeatureFlags}::DEFINITIONS", {
      test_feature_flag: test_definition
    }.freeze)
  end

  context "with feature_flags tasks loaded" do
    it "scopes project-specific changes by PROJECT_ID" do
      project = create(:project)
      duplicate_repo_project = create(:project, owner: project.owner, repo: project.repo)
      ENV["PROJECT_ID"] = project.id.to_s

      enable_task.invoke("test_feature_flag")

      expect(FeatureFlags.enabled?(:test_feature_flag, project: project)).to be(true)
      expect(FeatureFlags.enabled?(:test_feature_flag, project: duplicate_repo_project)).to be(false)
    end

    it "rejects ambiguous owner/repo selectors" do
      ENV["PROJECT"] = "owner/repo"

      expect {
        list_task.invoke
      }.to raise_error(ArgumentError, "Use PROJECT_ID=<id> for project-scoped feature flag changes")
    end

    it "rejects non-integer project ids" do
      ENV["PROJECT_ID"] = "owner/repo"

      expect {
        enable_task.invoke("test_feature_flag")
      }.to raise_error(ArgumentError, "PROJECT_ID must be an integer")
    end

    it "rejects project ids that do not exist" do
      ENV["PROJECT_ID"] = "-1"

      expect {
        list_task.invoke
      }.to raise_error(ArgumentError, "PROJECT_ID=-1 does not match an existing project")
    end

    it "configures percentage-of-actors rollouts" do
      enable_percentage_of_actors_task.invoke("test_feature_flag", "25")

      expect(FeatureFlags.rollout_status(:test_feature_flag)[:percentage_of_actors]).to eq(25)
    end

    it "configures percentage-of-time rollouts" do
      enable_percentage_of_time_task.invoke("test_feature_flag", "10")

      expect(FeatureFlags.rollout_status(:test_feature_flag)[:percentage_of_time]).to eq(10)
    end

    it "prints full rollout status" do
      ENV["PROJECT_ID"] = nil
      FeatureFlags.enable_percentage_of_actors(:test_feature_flag, 25)

      expect {
        SilenceStreams.call(:stdout) do
          status_task.invoke("test_feature_flag")
        end
      }.not_to raise_error
    end
  end
end
