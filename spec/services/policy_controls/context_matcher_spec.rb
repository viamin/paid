# frozen_string_literal: true

require "rails_helper"

RSpec.describe PolicyControls::ContextMatcher do
  describe ".matches?" do
    it "matches empty conditions" do
      expect(match({}, {})).to be(true)
    end

    it "supports numeric risk score comparisons with missing context values" do
      expect(match({ "risk_score_gte" => 0 }, {})).to be(true)
      expect(match({ "risk_score_gte" => 1 }, {})).to be(false)
      expect(match({ "risk_score_lte" => 0 }, {})).to be(true)
    end

    it "supports issue label and change surface list conditions" do
      context = {
        "issue_labels" => [ "bug", :security ],
        "change_surface" => [ "api", "db" ]
      }

      aggregate_failures do
        expect(match({ "issue_labels_any" => [ "security" ] }, context)).to be(true)
        expect(match({ "issue_labels_all" => [ "bug", "security" ] }, context)).to be(true)
        expect(match({ "issue_labels_all" => [] }, context)).to be(true)
        expect(match({ "change_surface_any" => [ "db" ] }, context)).to be(true)
        expect(match({ "change_surface_all" => [ "api", "db" ] }, context)).to be(true)
        expect(match({ "change_surface_all" => [] }, context)).to be(true)
      end
    end

    it "handles nil and wildcard values" do
      aggregate_failures do
        expect(match({ "runner_key" => nil }, {})).to be(true)
        expect(match({ "runner_key" => "any" }, {})).to be(true)
        expect(match({ "runner_key" => [ "any" ] }, {})).to be(true)
        expect(match({ "runner_key" => [ "codex" ] }, {})).to be(false)
      end
    end

    it "casts boolean values from non-boolean context inputs" do
      aggregate_failures do
        expect(match({ "regulated" => true }, { "regulated" => "1" })).to be(true)
        expect(match({ "regulated" => false }, { "regulated" => "false" })).to be(true)
        expect(match({ "regulated" => false }, { "regulated" => "0" })).to be(true)
      end
    end

    it "supports nested hash matching" do
      expect(
        match(
          { "service_containers" => { "redis" => true } },
          { "service_containers" => { "redis" => "1", "postgres" => false } }
        )
      ).to be(true)
    end

    it "matches array expectations against scalar context values" do
      expect(match({ "environment" => [ "production", "staging" ] }, { "environment" => :production })).to be(true)
    end
  end

  def match(conditions, context)
    described_class.matches?(conditions: conditions, context: context)
  end
end
