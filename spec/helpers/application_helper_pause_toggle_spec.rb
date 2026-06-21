# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db do
  describe "#issue_pause_confirm_message" do
    def stub_issue(github_number:, is_pull_request:)
      Struct.new(:github_number, :is_pull_request, keyword_init: true) do
        def is_pull_request?
          is_pull_request
        end
      end.new(github_number: github_number, is_pull_request: is_pull_request)
    end

    it "promises automation will skip an issue" do
      issue = stub_issue(github_number: 42, is_pull_request: false)

      message = helper.issue_pause_confirm_message(issue)

      expect(message).to include("Pause issue #42?")
      expect(message).to include("Automation will skip it")
      expect(message).to include(Issue::PAUSED_LABEL)
    end

    it "does not promise PR automation will stop for a pull request" do
      pr = stub_issue(github_number: 7, is_pull_request: true)

      message = helper.issue_pause_confirm_message(pr)

      expect(message).to include("Pause PR #7?")
      expect(message).not_to include("Automation will skip")
      expect(message).to include("PR review automation is not yet gated by pause")
    end
  end
end
