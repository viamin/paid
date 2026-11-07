# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::RecordPilotMetrics do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:revisions) do
    {
      "intent_revision" => "sha256:#{Digest::SHA256.hexdigest("intent")}",
      "acceptance_revision" => "sha256:#{Digest::SHA256.hexdigest("acceptance")}",
      "evidence_revision" => "sha256:#{Digest::SHA256.hexdigest("evidence")}"
    }
  end
  let(:reversals) do
    [
      {
        "settled_revision" => "sha256:#{Digest::SHA256.hexdigest("settled-1")}",
        "reversing_revision" => "sha256:#{Digest::SHA256.hexdigest("reversing-1")}",
        "material" => true,
        "attributable_to_delegated_work" => true
      },
      {
        "settled_revision" => "sha256:#{Digest::SHA256.hexdigest("settled-2")}",
        "reversing_revision" => "sha256:#{Digest::SHA256.hexdigest("reversing-2")}",
        "material" => false,
        "attributable_to_delegated_work" => false
      }
    ]
  end

  def record(**overrides)
    described_class.call(
      project:,
      posture: "bounded_delivery",
      window_started_at: 30.days.ago,
      window_ended_at: 1.day.ago,
      completed_issues: 30,
      total_issues: 32,
      decision_seconds: [ 600, 1200, 1800 ],
      reversals: [],
      exclusions: { "duplicate_decision" => 2 },
      revisions:,
      **overrides
    )
  end

  it "records revision-aware aggregates for the measured window" do
    metric = record(reversals:)

    expect(metric).to be_persisted
    expect(metric.posture).to eq("bounded_delivery")
    expect(metric.inbox_decisions).to eq(3)
    expect(metric.completed_issues).to eq(30)
    expect(metric.total_issues).to eq(32)
    expect(metric.completion_rate).to be_within(0.00001).of(0.9375)
    expect(metric.median_decision_seconds).to eq(1200.0)
    expect(metric.p90_decision_seconds).to eq(1800.0)
    expect(metric.reversed_decisions).to eq(2)
    expect(metric.reversal_rate).to be_within(0.00001).of(2.to_f / 3)
  end

  it "pins the measured revisions, exclusions, and reversal attribution" do
    metric = record(reversals:)

    expect(metric.material_attributable_reversals.size).to eq(1)
    expect(metric.revisions).to eq(revisions)
    expect(metric.exclusions).to eq("duplicate_decision" => 2)
  end

  it "keeps the decision samples and source evidence inspectable" do
    metric = record(decision_seconds: [ 60, 120 ], evidence: { "inbox_query" => "resolved notifications" })

    expect(metric.evidence).to include("decision_seconds" => [ 60, 120 ])
    expect(metric.evidence).to include("inbox_query" => "resolved notifications")
  end

  it "computes an even-count median as the mean of the two central samples" do
    metric = record(decision_seconds: [ 100, 200, 300, 400 ])

    expect(metric.median_decision_seconds).to eq(250.0)
  end

  it "computes p90 by nearest-rank over the sorted samples" do
    metric = record(decision_seconds: [ 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000 ])

    expect(metric.p90_decision_seconds).to eq(900.0)
  end

  it "records the conservative baseline cohort for the same project" do
    baseline = record(posture: "conservative", decision_seconds: [ 3000, 4000 ])

    expect(baseline.posture).to eq("conservative")
    expect(ProjectDelegation::PilotMetric.latest_for(project, "conservative")).to eq(baseline)
  end

  it "is idempotent per project, posture, and window start" do
    started = 30.days.ago
    first = record(window_started_at: started, decision_seconds: [ 3000 ])
    second = record(window_started_at: started, decision_seconds: [ 100, 200, 300 ])

    expect(second.id).to eq(first.id)
    expect(ProjectDelegation::PilotMetric.count).to eq(1)
    expect(second.inbox_decisions).to eq(3)
  end

  it "records an audit event for the measurement" do
    actor = create(:user, :member, account:)
    metric = record(actor:)

    event = account.account_activity_events.by_action("project_delegation.pilot_metrics_recorded").last
    expect(event).to have_attributes(actor:, subject: metric)
  end

  it "rejects an unknown posture with a typed error" do
    expect { record(posture: "unbounded") }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /posture/)
  end

  it "rejects a window that does not end after it starts" do
    expect { record(window_started_at: 2.days.ago, window_ended_at: 3.days.ago) }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /window/)
  end

  it "rejects more completed issues than measured issues" do
    expect { record(completed_issues: 33, total_issues: 32) }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /completed/)
  end

  it "rejects negative decision samples" do
    expect { record(decision_seconds: [ 60, -5 ]) }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /decision_seconds/)
  end

  it "rejects a reversal event without both revision tokens" do
    expect { record(reversals: [ { "settled_revision" => "r1", "material" => true } ]) }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /reversal/)
  end

  it "rejects measurements that do not pin every governing revision" do
    expect { record(revisions: revisions.except("evidence_revision")) }
      .to raise_error(ProjectDelegation::RecordPilotMetrics::InvalidMeasurement, /revision/)
  end
end
