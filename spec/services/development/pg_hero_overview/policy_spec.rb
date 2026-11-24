# frozen_string_literal: true

require "rails_helper"

RSpec.describe Development::PgHeroOverview::Policy do
  # @spec RAILS-CONTROL-PLANE-025
  it "classifies every Overview category as actionable, persistence-gated, or an excluded informational" do
    expect(described_class.persistence_required?(:long_running_query)).to be(true)
    expect(described_class.persistence_required?(:connection_pressure)).to be(true)
    expect(described_class.persistence_required?(:idle_in_transaction)).to be(true)
    expect(described_class.persistence_required?(:cache_hit_rate)).to be(true)

    %i[slow_query suggested_index invalid_index invalid_constraint duplicate_index
       unused_index sequence_danger unreadable_sequence xid_danger
       replication_slot query_stats_unavailable].each do |structural|
      expect(described_class.persistence_required?(structural)).to be(false)
    end
  end

  # @spec RAILS-CONTROL-PLANE-025
  it "records the documented informational exclusions with reasons" do
    exclusions = Development::PgHeroOverview::Policy::INFORMATIONAL_EXCLUSIONS

    expect(exclusions).to include(
      replication_lag: "The development database is a primary; the Overview's replica-only lag check does not apply.",
      autovacuum_long_running_queries: "Autovacuum workers appearing among long-running queries are expected maintenance."
    )
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "requires two consecutive observations before a transient finding is actionable" do
    expect(Development::PgHeroOverview::Policy::PERSISTENCE_ROUNDS).to eq(2)
  end

  # @spec RAILS-CONTROL-PLANE-028
  it "bounds new issues per run" do
    expect(Development::PgHeroOverview::Policy::MAX_NEW_ISSUES_PER_RUN).to be_positive
  end
end
