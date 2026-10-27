# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261027060229_backfill_required_good_job_queues")

RSpec.describe BackfillRequiredGoodJobQueues do # @spec INTENT-CONFORMANCE-ROLLOUT-011
  let(:migration) { described_class.new }

  it "serves the platform-required queue for a stored allocation that predates it" do
    setting = create(:tenant_setting, worker_settings: { "good_job_queues" => "default:3;maintenance:2" })

    migration.up

    expect(setting.reload.worker_settings["good_job_queues"])
      .to eq("default:3;maintenance:2;shadow_evaluation:1")
  end

  it "keeps a stored allocation that already serves the required queue" do
    setting = create(:tenant_setting,
      worker_settings: { "good_job_queues" => "default:3;shadow_evaluation:2" })

    migration.up

    expect(setting.reload.worker_settings["good_job_queues"])
      .to eq("default:3;shadow_evaluation:2")
  end

  it "reconciles the stored thread allocation with the stored thread budget" do
    setting = create(:tenant_setting, worker_settings: {
      "good_job_max_threads" => 11,
      "good_job_queues" => "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1"
    })

    migration.up

    expect(setting.reload.worker_settings["good_job_queues"])
      .to eq("default:3;maintenance:2;metrics:2;knowledge:2;low_priority:1;shadow_evaluation:1")
  end

  it "keeps the other worker settings untouched" do
    setting = create(:tenant_setting, worker_settings: {
      "good_job_queues" => "default:3",
      "temporal_workflow_slots" => 30
    })

    migration.up

    expect(setting.reload.worker_settings["temporal_workflow_slots"]).to eq(30)
  end

  it "leaves a stored allocation without a queue setting untouched" do
    setting = create(:tenant_setting, worker_settings: { "temporal_workflow_slots" => 30 })

    migration.up

    expect(setting.reload.worker_settings).to eq("temporal_workflow_slots" => 30)
  end
end
