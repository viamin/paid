# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntegrationsHelper do
  describe "#render_integration_status" do
    def build_record(**attrs)
      Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
    end

    it "shows Revoked when the token is revoked" do
      record = build_record(revoked?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Revoked")
      expect(result).to include("bg-gray-100")
    end

    it "shows Expired when the token is expired" do
      record = build_record(expired?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Expired")
      expect(result).to include("bg-orange-100")
    end

    it "shows Validation Failed when validation failed" do
      record = build_record(validation_failed?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Validation Failed")
      expect(result).to include("bg-red-100")
    end

    it "shows Validation Stuck when validation is stale" do
      record = build_record(validation_stale?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Validation Stuck")
      expect(result).to include("bg-yellow-100")
    end

    it "shows Validating when actively validating" do
      record = build_record(validating?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Validating...")
      expect(result).to include("bg-yellow-100")
    end

    it "shows Pending Validation when validation is pending" do
      record = build_record(validation_pending?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Pending Validation")
      expect(result).to include("bg-yellow-100")
    end

    it "shows Expiring Soon when token expires within 7 days" do
      record = build_record(expires_at: 3.days.from_now)
      result = helper.render_integration_status(record)

      expect(result).to include("Expiring Soon")
      expect(result).to include("bg-orange-100")
    end

    it "shows Active when token is not expiring soon" do
      record = build_record(expires_at: 30.days.from_now)
      result = helper.render_integration_status(record)

      expect(result).to include("Active")
      expect(result).to include("bg-green-100")
    end

    it "shows Active when no status methods are present" do
      record = Object.new
      result = helper.render_integration_status(record)

      expect(result).to include("Active")
      expect(result).to include("bg-green-100")
    end

    it "prioritizes Revoked over Expired" do
      record = build_record(revoked?: true, expired?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Revoked")
    end

    it "prioritizes Expired over Validation Failed" do
      record = build_record(expired?: true, validation_failed?: true)
      result = helper.render_integration_status(record)

      expect(result).to include("Expired")
    end

    it "renders a span element with badge styling" do
      record = Object.new
      result = helper.render_integration_status(record)

      expect(result).to have_css("span.inline-flex")
    end
  end
end
