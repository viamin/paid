# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkerSettings::GoodJobQueues do # @spec INTENT-CONFORMANCE-ROLLOUT-011
  describe ".normalize" do
    it "adds the platform-required queue to a persisted allocation that predates it" do
      normalized = described_class.normalize("default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1")

      expect(normalized).to eq("default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1;shadow_evaluation:1")
    end

    it "keeps an existing required queue allocation" do
      normalized = described_class.normalize("default:3;shadow_evaluation:2")

      expect(normalized).to eq("default:3;shadow_evaluation:2")
    end

    it "raises a below-minimum required queue allocation to the minimum" do
      expect(described_class.normalize("default:3;shadow_evaluation:0"))
        .to eq("default:3;shadow_evaluation:1")
    end

    it "leaves an unparseable value untouched so validation can report it" do
      expect(described_class.normalize("invalid")).to eq("invalid")
    end

    it "leaves a blank value untouched" do
      expect(described_class.normalize("")).to eq("")
    end
  end

  describe ".reconcile" do
    it "keeps the required queue served when the allocation fits the budget" do
      reconciled = described_class.reconcile(
        "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1",
        max_threads: 12
      )

      expect(reconciled).to eq("default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1;shadow_evaluation:1")
    end

    it "reclaims threads from the lowest-priority queue when the required queue exceeds the budget" do
      reconciled = described_class.reconcile(
        "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:2",
        max_threads: 12
      )

      expect(reconciled).to eq("default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1;shadow_evaluation:1")
    end

    it "never reclaims the required queue threads" do
      reconciled = described_class.reconcile(
        "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1",
        max_threads: 11
      )

      expect(reconciled).to include("shadow_evaluation:1")
      expect(thread_total(reconciled)).to eq(11)
    end

    it "keeps a single thread for every served queue when the budget is smaller than the queue count" do
      reconciled = described_class.reconcile(
        "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1",
        max_threads: 3
      )

      expect(thread_total(reconciled)).to eq(6)
    end

    it "leaves an unparseable value untouched" do
      expect(described_class.reconcile("invalid", max_threads: 12)).to eq("invalid")
    end

    it "reports an allocation that cannot fit the budget" do
      allow(Rails.logger).to receive(:warn)

      described_class.reconcile("default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1", max_threads: 3)

      expect(Rails.logger).to have_received(:warn).with(hash_including(message: "worker_settings.good_job_queues.budget_exceeded"))
    end
  end

  describe ".parse" do
    it "returns the queue threads keyed by queue name" do
      expect(described_class.parse("default:3;shadow_evaluation:1")).to eq("default" => 3, "shadow_evaluation" => 1)
    end

    it "returns nil for a value without thread counts" do
      expect(described_class.parse("default")).to be_nil
    end

    it "returns nil for a non-numeric thread count" do
      expect(described_class.parse("default:many")).to be_nil
    end
  end

  def thread_total(queue_string)
    queue_string.split(";").sum { |entry| entry.split(":").last.to_i }
  end
end
