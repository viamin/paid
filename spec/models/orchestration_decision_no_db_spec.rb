# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationDecision, :no_db do
  describe ".analytics_status_group" do
    it "groups only explicit success statuses as successful" do
      expect(described_class.analytics_status_group("applied")).to eq("successful")
      expect(described_class.analytics_status_group("deferred")).to eq("successful")
      expect(described_class.analytics_status_group("resolved")).to eq("successful")
    end

    it "keeps unknown statuses out of the success bucket" do
      expect(described_class.analytics_status_group("escalated")).to eq("other")
      expect(described_class.analytics_status_group("typo")).to eq("other")
    end
  end
end
