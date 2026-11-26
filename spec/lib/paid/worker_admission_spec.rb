# frozen_string_literal: true

require "rspec"
require "fileutils"
require "tmpdir"
require_relative "../../../bin/lib/worker_admission_slot_supplier"

RSpec.describe Paid::WorkerAdmission do # @spec TEMPORAL-ORCHESTRATION-021
  let(:directory) { Dir.mktmpdir("worker-admission") }
  let(:readiness_file) { File.join(directory, "worker-ready") }
  let(:lock_path) { "#{readiness_file}.admission.lock" }
  let(:request_path) { "#{readiness_file}.admission.request" }
  let(:supplier) { Paid::WorkerAdmission::SlotSupplier.new(slots: 1, readiness_file:) }
  let(:permits) { [] }

  after do
    permits.each { |permit| permit.lock.close unless permit.lock.closed? }
    FileUtils.remove_entry(directory)
  end

  def reserve
    permit = supplier.try_reserve_slot(nil)
    permits << permit if permit
    permit
  end

  def release(permit)
    supplier.release_slot(Struct.new(:permit).new(permit))
    permits.delete(permit)
  end

  def exclusive_available?
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      !!lock.flock(File::LOCK_EX | File::LOCK_NB)
    end
  end

  def request_drain
    File.write(request_path, '{"generation":"fixture-owned"}')
  end

  def reserve_poll(from: supplier, sticky: false)
    cancellation = Struct.new(:canceled?).new(false)
    allow(cancellation).to receive(:canceled?).and_return(false, false, true)
    result = nil
    from.reserve_slot(Struct.new(:sticky?).new(sticky), cancellation) do |permit|
      permits << permit
      result = permit
    end
    result
  end

  def worker_profile(activity_slots: 4)
    { "workflow_slots" => 4, "activity_slots" => activity_slots, "local_activity_slots" => activity_slots,
      "workflow_task_polls" => 4, "activity_task_polls" => activity_slots }
  end

  it "owns an unused reservation before any task-used notification" do
    expect(reserve).not_to be_nil
    expect(exclusive_available?).to be(false)
  end

  it "preserves capacity until the SDK releases an unused reservation" do
    permit = reserve
    expect(reserve).to be_nil
    release(permit)
    expect(exclusive_available?).to be(true)
    expect(reserve).not_to be_nil
    expect(reserve).to be_nil
  end

  it "retains ownership when a drain is requested after reservation" do
    permit = reserve
    request_drain
    expect(exclusive_available?).to be(false)
    release(permit)
    expect(exclusive_available?).to be(true)
  end

  it "refuses eager reservation when a drain request already exists" do
    request_drain
    expect(reserve).to be_nil
  end

  it "does not renew a released reservation during a pending drain" do
    permit = reserve
    request_drain
    release(permit)
    expect(reserve).to be_nil
  end

  it "fails closed for an unrecognizable request entry" do
    File.symlink(File.join(directory, "missing-owner"), request_path)
    expect(reserve).to be_nil
  end

  it "resumes without losing slot capacity after the owned request is removed" do
    request_drain
    expect(reserve).to be_nil
    File.unlink(request_path)
    expect(reserve).not_to be_nil
    expect(reserve).to be_nil
  end

  it "does not perform path I/O in a task-used notification" do
    permit = reserve
    request_drain
    File.open(lock_path, File::RDWR) do |probe|
      expect(File).not_to receive(:open)
      expect(File).not_to receive(:read)
      expect(File).not_to receive(:write)
      supplier.mark_slot_used(Struct.new(:permit).new(permit))
      expect(probe.flock(File::LOCK_EX | File::LOCK_NB)).to be(false)
    end
  end

  it "does not issue a permit for an already cancelled reservation" do
    cancellation = Struct.new(:canceled?).new(true)
    expect { |block| supplier.reserve_slot(nil, cancellation, &block) }.not_to yield_control
    expect(reserve).not_to be_nil
  end

  it "returns an acquired permit when cancellation arrives before delivery" do
    cancellation = Struct.new(:canceled?).new(false)
    allow(File).to receive(:open).and_wrap_original do |original, *arguments|
      original.call(*arguments).tap { cancellation[:canceled?] = true if arguments.first == lock_path }
    end
    expect { |block| supplier.reserve_slot(nil, cancellation, &block) }.not_to yield_control
    allow(File).to receive(:open).and_call_original
    expect(reserve).not_to be_nil
    expect(reserve).to be_nil
  end

  it "returns capacity when a request arrives during lock acquisition" do
    allow(File).to receive(:open).and_wrap_original do |original, *arguments|
      original.call(*arguments).tap { request_drain if arguments.first == lock_path }
    end
    expect(reserve).to be_nil
    File.unlink(request_path)
    allow(File).to receive(:open).and_call_original
    expect(reserve).not_to be_nil
    expect(reserve).to be_nil
  end

  it "returns capacity after an admission lock cannot be opened" do
    allow(File).to receive(:open).with(lock_path, anything, anything).and_raise(Errno::EACCES)
    expect(reserve).to be_nil
    allow(File).to receive(:open).and_call_original
    expect(reserve).not_to be_nil
    expect(reserve).to be_nil
  end

  it "waits cancellably without issuing a permit while admission is closed" do
    request_drain
    cancellation = Struct.new(:canceled?).new(false)
    yielded = Queue.new
    thread = Thread.new { supplier.reserve_slot(nil, cancellation) { |permit| yielded << permit } }
    cancellation[:canceled?] = true
    expect(thread.join(1)).to eq(thread)
    expect(yielded).to be_empty
  ensure
    thread&.kill
    thread&.join
  end

  it "tracks independent workflow and activity capacities on one admission inode" do
    activity = Paid::WorkerAdmission::SlotSupplier.new(slots: 1, readiness_file:)
    workflow_permit = reserve
    activity_permit = activity.try_reserve_slot(nil)
    expect(activity_permit).not_to be_nil
    expect(exclusive_available?).to be(false)
    release(workflow_permit)
    expect(exclusive_available?).to be(false)
    activity.release_slot(Struct.new(:permit).new(activity_permit))
    expect(exclusive_available?).to be(true)
  ensure
    activity_permit&.lock&.close unless activity_permit&.lock&.closed?
  end

  it "rejects nonpositive capacity" do
    expect { Paid::WorkerAdmission::SlotSupplier.new(slots: 0, readiness_file:) }.to raise_error(ArgumentError)
    expect { Paid::WorkerAdmission::SlotSupplier.new(slots: -1, readiness_file:) }.to raise_error(ArgumentError)
  end

  it "preserves the fixed local supplier and independent configured remote capacities" do
    tuner = described_class.tuner(
      workflow_slots: 2, activity_slots: 1, local_activity_slots: 3,
      workflow_task_polls: 2, activity_task_polls: 1, readiness_file:
    )
    expect(tuner.local_activity_slot_supplier).to be_a(Temporalio::Worker::Tuner::SlotSupplier::Fixed)
    expect(tuner.local_activity_slot_supplier.slots).to eq(3)
    first = tuner.workflow_slot_supplier.try_reserve_slot(nil)
    second = tuner.workflow_slot_supplier.try_reserve_slot(nil)
    third = tuner.activity_slot_supplier.try_reserve_slot(nil)
    expect([ first, second, third ]).not_to include(nil)
    expect(tuner.workflow_slot_supplier.try_reserve_slot(nil)).to be_nil
    expect(tuner.activity_slot_supplier.try_reserve_slot(nil)).to be_nil
    request_drain
    expect(exclusive_available?).to be(false)
  ensure
    [ first, second, third ].compact.each { |permit| permit.lock.close unless permit.lock.closed? }
  end

  context "with unused poll reservations" do
    let(:supplier) { Paid::WorkerAdmission::SlotSupplier.new(slots: 4, readiness_file:) }

    it "does not prefetch another permit behind a full poller" do
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll).to be_nil
      expect(exclusive_available?).to be(false)
    end

    it "keeps sticky and nonsticky poll budgets independent" do
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll(sticky: true)).not_to be_nil
      expect(reserve_poll).to be_nil
      expect(reserve_poll(sticky: true)).to be_nil
    end

    it "returns poll capacity on assignment while retaining all execution slots and locks" do
      first = reserve_poll
      supplier.mark_slot_used(Struct.new(:permit).new(first))
      expect(reserve_poll).not_to be_nil
      expect(reserve).not_to be_nil
      expect(reserve).not_to be_nil
      expect(reserve).to be_nil
      expect(exclusive_available?).to be(false)
      release(first)
      expect(exclusive_available?).to be(false)
    end

    it "does not charge eager permits against the unused poll budget" do
      expect(reserve).not_to be_nil
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll).to be_nil
      expect(reserve).not_to be_nil
    end

    it "does not return the poll budget twice when an assigned slot is released" do
      first = reserve_poll
      supplier.mark_slot_used(Struct.new(:permit).new(first))
      release(first)
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll).to be_nil
    end

    it "restores both budgets when cancellation wins before permit delivery" do
      cancellation = Struct.new(:canceled?).new(false)
      allow(File).to receive(:open).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { cancellation[:canceled?] = true }
      end
      expect { |block| supplier.reserve_slot(nil, cancellation, &block) }.not_to yield_control
      allow(File).to receive(:open).and_call_original
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll).to be_nil
    end

    it "restores both budgets when the admission lock cannot be opened" do
      allow(File).to receive(:open).with(lock_path, anything, anything).and_raise(Errno::EACCES)
      expect(reserve_poll).to be_nil
      allow(File).to receive(:open).and_call_original
      expect(reserve_poll).not_to be_nil
      expect(reserve_poll).to be_nil
    end

    it "uses poller counts rather than execution slots for the public fixed split" do
      tuner = described_class.tuner(
        workflow_slots: 12, activity_slots: 8, local_activity_slots: 8,
        workflow_task_polls: 5, activity_task_polls: 2, readiness_file:
      )
      workflow = tuner.workflow_slot_supplier
      expect(reserve_poll(from: workflow)).not_to be_nil
      expect(reserve_poll(from: workflow)).to be_nil
      4.times { expect(reserve_poll(from: workflow, sticky: true)).not_to be_nil }
      expect(reserve_poll(from: workflow, sticky: true)).to be_nil
      activity = tuner.activity_slot_supplier
      2.times { expect(reserve_poll(from: activity)).not_to be_nil }
      expect(reserve_poll(from: activity)).to be_nil
    end
  end

  it "captures both logical roles in one immutable process boot identity" do
    profiles = { "poll" => worker_profile(activity_slots: 2), "agent" => worker_profile }
    identity = described_class.boot_identity(workspace: directory, revision: "a" * 40, profiles:)
    expect(identity.fetch("pid")).to eq(Process.pid)
    expect(identity.fetch("process_start_ticks")).to be_positive
    expect(identity.fetch("workspace")).to eq(File.realpath(directory))
    expect(identity.fetch("profiles")).to eq(profiles)
    expect(identity.fetch("profiles")).to be_frozen
    expect(identity.fetch("boot_id")).to match(/\A[0-9a-f-]{36}\z/)
    expect(identity).to be_frozen
  end

  it "does not share a boot identity between successive process registrations" do
    args = { workspace: directory, revision: "a" * 40, profiles: { "agent" => worker_profile } }
    expect(described_class.boot_identity(**args).fetch("boot_id"))
      .not_to eq(described_class.boot_identity(**args).fetch("boot_id"))
  end

  it "refuses to advertise an unknown revision or worker role" do
    expect { described_class.boot_identity(workspace: directory, revision: nil, profiles: { "agent" => {} }) }
      .to raise_error(ArgumentError)
    expect { described_class.boot_identity(workspace: directory, revision: "a" * 40, profiles: { "other" => {} }) }
      .to raise_error(ArgumentError)
  end
end
