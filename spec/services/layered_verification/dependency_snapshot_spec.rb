# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::DependencySnapshot do
  # @spec LAYERED-VERIFY-019
  it "stamps the concrete Paid process revision" do
    project = create(:project)

    snapshot = described_class.call(project:, paid_revision: "paid-revision")

    expect(snapshot.dig("producer_versions", "paid")).to eq("paid-revision")
  end

  # @spec LAYERED-VERIFY-019
  it "rejects admission when the Paid process revision is unavailable" do
    project = create(:project)

    expect { described_class.call(project:, paid_revision: nil) }
      .to raise_error(described_class::UnknownProducerVersionError, /Paid revision/)
  end
end
