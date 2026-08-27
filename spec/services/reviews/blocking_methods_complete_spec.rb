# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::BlockingMethodsComplete do
  describe ".manual_review_complete?" do
    let(:project) do
      create(:project,
        allowed_github_usernames: [ "alice" ],
        review_settings: {
          "enabled" => true,
          "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
        })
    end

    # @spec PR-ESCALATION-025
    it "uses the configured reviewer's latest review state" do
      reviews = [
        { id: 1, user_login: "alice", state: "APPROVED", submitted_at: 2.hours.ago },
        { id: 2, user_login: "alice", state: "COMMENTED", submitted_at: 1.hour.ago }
      ]

      expect(described_class.manual_review_complete?(project:, reviews:)).to be(false)
    end

    # @spec PR-ESCALATION-025
    it "is trust-free: the configured reviewer's approval counts even when not in allowed_github_usernames" do
      project.update!(allowed_github_usernames: [ "someone-else" ])
      reviews = [ { id: 1, user_login: "alice", state: "APPROVED", submitted_at: 1.hour.ago } ]

      expect(described_class.manual_review_complete?(project:, reviews:)).to be(true)
    end
  end
end
