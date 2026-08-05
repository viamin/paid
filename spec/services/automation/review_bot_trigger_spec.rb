# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewBotTrigger do # @spec QUALITY-LOOPS-006
  subject(:instance) { klass.new }

  let(:klass) do
    Class.new do
      include Automation::ReviewBotTrigger
      public :review_bot_reviewers_from
    end
  end

  describe "#review_bot_reviewers_from" do
    it "returns an empty array for nil trigger" do
      expect(instance.review_bot_reviewers_from(nil)).to eq([])
    end

    it "returns the chain when request_logins is present" do
      trigger = { request_logins: %w[bot-a bot-b] }
      expect(instance.review_bot_reviewers_from(trigger)).to eq(%w[bot-a bot-b])
    end

    it "strips nils from request_logins" do
      trigger = { request_logins: [ "bot-a", nil, "bot-b" ] }
      expect(instance.review_bot_reviewers_from(trigger)).to eq(%w[bot-a bot-b])
    end

    it "falls back to request_login when request_logins is absent" do
      trigger = { request_login: "legacy-bot" }
      expect(instance.review_bot_reviewers_from(trigger)).to eq([ "legacy-bot" ])
    end

    it "falls back to request_login when request_logins is empty" do
      trigger = { request_logins: [], request_login: "legacy-bot" }
      expect(instance.review_bot_reviewers_from(trigger)).to eq([ "legacy-bot" ])
    end

    it "returns an empty array when neither field is present" do
      trigger = { type: "review_bot_review_pending" }
      expect(instance.review_bot_reviewers_from(trigger)).to eq([])
    end
  end
end
