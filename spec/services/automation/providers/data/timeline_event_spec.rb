# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::TimelineEvent do
  it "captures the event type, actor, and optional label" do
    event = described_class.new(
      event: :labeled, actor_login: "alice",
      label_name: "paid-build", created_at: Time.at(0),
      raw: { event: "labeled" }
    )

    expect(event.event).to eq(:labeled)
    expect(event.label_name).to eq("paid-build")
  end

  it "declares the provider-neutral event enum" do
    expect(described_class::EVENTS).to include(:labeled, :unlabeled, :closed, :merged)
  end
end
