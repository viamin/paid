# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::Adapters::GithubIssues do
  IssueTrackers::AdapterFactory::ADAPTERS.each_key do |tracker_type|
    it "suppresses #{tracker_type} comments for a project-scoped tracker" do
      # @spec QUIET-MODE-004
      configuration = create(:tracker_configuration, :for_project, tracker_type: tracker_type)
      configuration.configurable.update!(quiet_mode: true)

      expect(configuration.adapter.add_comment(external_id: "ABC-42", body: "status")).to be_nil
    end
  end
end
