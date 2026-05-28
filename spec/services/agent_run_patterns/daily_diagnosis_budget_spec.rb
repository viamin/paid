# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::DailyDiagnosisBudget do
  let(:account) { create(:account) }

  it "counts diagnosis attempts recorded today instead of raw decision rows" do
    create(
      :remediation_decision,
      account: account,
      diagnosis_attempted_on: Date.current,
      diagnosis_attempt_count_on_day: 4
    )
    create(
      :remediation_decision,
      account: account,
      diagnosis_attempted_on: 1.day.ago.to_date,
      diagnosis_attempt_count_on_day: 9
    )

    expect(described_class.new(account: account).send(:diagnoses_attempted_today)).to eq(4)
    expect(described_class.remaining_for(account: account)).to eq(16)
  end
end
