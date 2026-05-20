# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccountActivityEvent do
  describe "#description" do
    it "renders a human-friendly invitation message" do
      event = described_class.new(action: "membership.invited", metadata: {
        "email" => "person@example.com",
        "role" => "admin"
      })

      expect(event.description).to eq("Invited person@example.com as admin")
    end

    it "falls back to unknown values when metadata is missing" do
      event = described_class.new(action: "membership.role_changed", metadata: {})

      expect(event.description).to eq("Changed unknown from unknown to unknown")
    end
  end
end
