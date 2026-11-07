# frozen_string_literal: true

require "rails_helper"
require "paid/puma_boot"

RSpec.describe Paid::PumaBoot do
  describe ".clear_active_record_connections!" do
    it "delegates to ActiveRecord::Base.connection_handler.clear_all_connections!" do
      handler = double("ConnectionHandler") # rubocop:disable RSpec/VerifiedDoubles
      allow(ActiveRecord::Base).to receive(:connection_handler).and_return(handler)
      expect(handler).to receive(:clear_all_connections!)

      described_class.clear_active_record_connections!
    end

    it "is a no-op when ActiveRecord has not been loaded" do
      hide_const("ActiveRecord")
      expect { described_class.clear_active_record_connections! }.not_to raise_error
    end
  end

  describe ".shutdown_good_job!" do
    it "delegates to GoodJob.shutdown" do
      expect(GoodJob).to receive(:shutdown)

      described_class.shutdown_good_job!
    end

    it "is a no-op when GoodJob has not been loaded" do
      hide_const("GoodJob")
      expect { described_class.shutdown_good_job! }.not_to raise_error
    end
  end

  describe ".restart_good_job!" do
    it "delegates to GoodJob.restart" do
      expect(GoodJob).to receive(:restart)

      described_class.restart_good_job!
    end

    it "is a no-op when GoodJob has not been loaded" do
      hide_const("GoodJob")
      expect { described_class.restart_good_job! }.not_to raise_error
    end
  end

  describe ".reset_temporal_client!" do
    it "delegates to Paid.reset_temporal_client!" do
      expect(Paid).to receive(:reset_temporal_client!)

      described_class.reset_temporal_client!
    end
  end

  describe ".warm_temporal_client_async" do
    it "returns a Thread that calls Paid.temporal_client" do
      expect(Paid).to receive(:temporal_client).and_return(:stubbed_client)

      thread = described_class.warm_temporal_client_async
      thread.join

      expect(thread).to be_a(Thread)
    end

    it "names the thread for observability" do
      allow(Paid).to receive(:temporal_client)

      thread = described_class.warm_temporal_client_async
      thread.join

      expect(thread.name).to eq("paid-temporal-warm")
    end

    it "swallows connect failures so worker boot is not blocked" do
      allow(Paid).to receive(:temporal_client).and_raise(StandardError, "connection refused")
      allow(described_class).to receive(:warn)

      thread = described_class.warm_temporal_client_async
      thread.join

      expect(described_class).to have_received(:warn).with(/connection refused/)
    end
  end

  describe ".call_after_fork" do
    it "clears connections, restarts GoodJob, resets the temporal client, and warms in the background" do
      handler = double("ConnectionHandler") # rubocop:disable RSpec/VerifiedDoubles
      allow(ActiveRecord::Base).to receive(:connection_handler).and_return(handler)
      allow(handler).to receive(:clear_all_connections!)
      allow(GoodJob).to receive(:restart)
      allow(Paid).to receive(:reset_temporal_client!)
      allow(Paid).to receive(:temporal_client)

      thread = described_class.call_after_fork
      thread.join

      expect(handler).to have_received(:clear_all_connections!)
      expect(GoodJob).to have_received(:restart)
      expect(Paid).to have_received(:reset_temporal_client!)
      expect(Paid).to have_received(:temporal_client)
    end

    it "restarts GoodJob only after clearing ActiveRecord connections" do # @spec RAILS-CONTROL-PLANE-013
      call_order = []
      allow(ActiveRecord::Base.connection_handler).to receive(:clear_all_connections!) { call_order << :clear_connections }
      allow(GoodJob).to receive(:restart) { call_order << :restart_good_job }
      allow(Paid).to receive(:reset_temporal_client!)
      allow(Paid).to receive(:temporal_client)

      described_class.call_after_fork.join

      expect(call_order).to eq([ :clear_connections, :restart_good_job ])
    end
  end
end
