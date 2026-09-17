# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-005
RSpec.describe DesignAmendments::PauseSet do
  it "holds exactly the affected branches plus their dependency closure" do
    adjacency = {
      1 => [ 2 ],  # issue 1 depends on affected issue 2
      3 => [ 1 ],  # issue 3 transitively depends on affected issue 2
      4 => [ 5 ]   # independent chain
    }

    pause_set = described_class.build(affected_issue_ids: [ 2 ], adjacency: adjacency)

    expect(pause_set).to eq(2 => "affected", 1 => "dependent", 3 => "dependent")
  end

  it "marks direct dependents before transitive ones without duplicating entries" do
    adjacency = { 10 => [ 11 ], 12 => [ 10 ] }

    pause_set = described_class.build(affected_issue_ids: [ 11, 12 ], adjacency: adjacency)

    expect(pause_set).to eq(11 => "affected", 12 => "affected", 10 => "dependent")
  end

  it "returns the affected set unchanged when nothing depends on it" do
    pause_set = described_class.build(affected_issue_ids: [ 7 ], adjacency: {})

    expect(pause_set).to eq(7 => "affected")
  end
end
