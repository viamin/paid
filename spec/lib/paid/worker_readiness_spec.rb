# frozen_string_literal: true

require "rails_helper"
require "paid/worker_readiness"

RSpec.describe Paid::WorkerReadiness do
  let(:tmpdir) { Dir.mktmpdir }
  let(:file_path) { File.join(tmpdir, "worker-ready") }

  after do
    FileUtils.chmod_R(0o755, tmpdir) if File.directory?(tmpdir)
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  describe ".file_path" do
    it "returns the WORKER_READINESS_FILE env var when set" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect(described_class.file_path(env)).to eq(file_path)
    end

    it "falls back to a program-scoped default in the system tmpdir" do
      path = described_class.file_path({})
      expect(path).to start_with(Dir.tmpdir)
      expect(path).to include("paid-worker-ready")
      # The default embeds the running program so it is unique per process.
      expect(path).to include(File.basename($PROGRAM_NAME, ".*"))
    end

    it "gives poll and agent temporal workers distinct flag paths" do
      poll = described_class.file_path("TEMPORAL_WORKER_MODE" => "poll")
      agent = described_class.file_path("TEMPORAL_WORKER_MODE" => "agent")
      expect(poll).to end_with("-poll")
      expect(agent).to end_with("-agent")
      expect(poll).not_to eq(agent)
    end
  end

  describe ".default_file_name" do
    it "includes the program basename" do
      expect(described_class.default_file_name({})).to include(File.basename($PROGRAM_NAME, ".*"))
    end

    it "appends TEMPORAL_WORKER_MODE when set" do
      name = described_class.default_file_name("TEMPORAL_WORKER_MODE" => "agent")
      expect(name).to eq("paid-worker-ready-#{File.basename($PROGRAM_NAME, '.*')}-agent")
    end

    it "omits the mode suffix when TEMPORAL_WORKER_MODE is absent" do
      expect(described_class.default_file_name({})).to eq(
        "paid-worker-ready-#{File.basename($PROGRAM_NAME, '.*')}"
      )
    end
  end

  describe ".mark_ready!" do
    it "creates the readiness file" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      expect(File.exist?(file_path)).to be true
    end

    it "writes JSON with pid and timestamp" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      payload = JSON.parse(File.read(file_path))
      expect(payload["pid"]).to eq(Process.pid)
      expect(payload["ready_at"]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    # @spec TEMPORAL-ORCHESTRATION-017
    it "publishes a coarse active activity count without exposing activity data" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      described_class.activity_started!(env)
      active_payload = JSON.parse(File.read(file_path))
      expect(active_payload).to include("active_activities" => 1)
      expect(active_payload.keys).to match_array(%w[pid ready_at revision active_activities])

      described_class.activity_finished!(env)
      expect(JSON.parse(File.read(file_path))).to include("active_activities" => 0)
    end

    # @spec TEMPORAL-ORCHESTRATION-017
    it "observes activity ownership without claiming to control SDK admission" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)
      activity, release = start_owned_activity(env)
      expect(JSON.parse(File.read(file_path))).to include("active_activities" => 1)
      release << true
      activity.join
      expect(JSON.parse(File.read(file_path))).to include("active_activities" => 0)
    ensure
      release << true if activity&.alive?
      activity&.join
    end

    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-003
    it "writes JSON with the booted checkout revision" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      payload = JSON.parse(File.read(file_path))
      expect(payload["revision"]).to eq(`git -C #{Rails.root} rev-parse HEAD`.strip)
    end

    it "prefers PAID_DEPLOYED_REVISION for the payload revision when set" do
      env = { "WORKER_READINESS_FILE" => file_path, "PAID_DEPLOYED_REVISION" => "deployed-sha" }
      described_class.mark_ready!(env)

      payload = JSON.parse(File.read(file_path))
      expect(payload["revision"]).to eq("deployed-sha")
    end

    # @spec TEMPORAL-ORCHESTRATION-017
    it "retains the boot revision while activity ownership changes" do
      env = { "WORKER_READINESS_FILE" => file_path, "PAID_DEPLOYED_REVISION" => "booted-sha" }
      described_class.mark_ready!(env)
      env["PAID_DEPLOYED_REVISION"] = "checkout-changed-after-boot"

      described_class.activity_started!(env)

      expect(JSON.parse(File.read(file_path))).to include(
        "revision" => "booted-sha",
        "active_activities" => 1
      )
    ensure
      described_class.activity_finished!(env)
    end

    it "reports a null revision when the checkout revision cannot be determined" do
      env = { "WORKER_READINESS_FILE" => file_path }
      allow(Open3).to receive(:capture3).and_return([ "", "", double(success?: false) ])

      described_class.mark_ready!(env)

      payload = JSON.parse(File.read(file_path))
      expect(payload["revision"]).to be_nil
    end

    it "creates parent directories if needed" do
      nested = File.join(tmpdir, "deep", "nested", "ready")
      described_class.mark_ready!("WORKER_READINESS_FILE" => nested)

      expect(File.exist?(nested)).to be true
    end

    it "does not raise when the file cannot be written" do
      env = { "WORKER_READINESS_FILE" => file_path }
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(/#{Regexp.escape(file_path)}\.#{Process.pid}\.tmp/, file_path)
        .and_raise(Errno::EACCES, file_path)

      expect { described_class.mark_ready!(env) }
        .to output(/Failed to write worker readiness file: Errno::EACCES/).to_stderr
    end
  end

  describe ".mark_not_ready!" do
    it "removes the readiness file" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)
      expect(File.exist?(file_path)).to be true

      described_class.mark_not_ready!(env)
      expect(File.exist?(file_path)).to be false
    end

    it "does not raise when the file does not exist" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect { described_class.mark_not_ready!(env) }.not_to raise_error
    end

    it "does not raise when the file cannot be deleted" do
      File.write(file_path, "ready")
      env = { "WORKER_READINESS_FILE" => file_path }
      allow(File).to receive(:delete).and_call_original
      allow(File).to receive(:delete).with(file_path).and_raise(Errno::EACCES, file_path)

      expect { described_class.mark_not_ready!(env) }
        .to output(/Failed to remove worker readiness file: Errno::EACCES/).to_stderr
    end
  end

  describe ".ready?" do
    it "returns true after mark_ready!" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)

      expect(described_class.ready?(env)).to be true
    end

    it "returns false after mark_not_ready!" do
      env = { "WORKER_READINESS_FILE" => file_path }
      described_class.mark_ready!(env)
      described_class.mark_not_ready!(env)

      expect(described_class.ready?(env)).to be false
    end

    it "returns false when no file exists" do
      env = { "WORKER_READINESS_FILE" => file_path }
      expect(described_class.ready?(env)).to be false
    end
  end

  def start_owned_activity(env)
    entered = Queue.new
    release = Queue.new
    activity = Thread.new do
      described_class.with_activity_observation(env) do
        entered << true
        release.pop
      end
    end
    entered.pop
    [ activity, release ]
  end
end
