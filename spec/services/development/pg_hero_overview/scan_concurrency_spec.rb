# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Development::PgHeroOverview::Scan do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:schema) { "pghero_scan_lock_#{SecureRandom.hex(6)}" }
  let(:fixture_table) { "#{schema}.scan_projects" }
  let!(:lock_model) do
    stub_const("PgHeroScanLockTarget", Class.new(ActiveRecord::Base)).tap do |model|
      model.table_name = fixture_table
    end
  end
  let(:project) { lock_model.create!(id: SecureRandom.random_number(1 << 52) + 1, name: "before") }

  around do |example|
    connection.execute("CREATE SCHEMA #{schema}")
    begin
      connection.create_table(fixture_table) { |t| t.string :name }
      example.run
    ensure
      connection.execute("DROP SCHEMA #{schema} CASCADE")
    end
  end

  before do
    stub_const("PgHeroScanInterrupted", Class.new(StandardError))
  end

  # @spec RAILS-CONTROL-PLANE-039
  it "allows routine project writes while a scan waits for external collection" do
    with_waiting_scan(project) do
      expect do
        with_lock_deadline { lock_model.where(id: project.id).update_all(name: "updated") }
      end.not_to raise_error
      expect(project.reload.name).to eq("updated")
    end
  end

  # @spec RAILS-CONTROL-PLANE-026 RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-039
  it "serializes concurrent scans of the same project across connections" do
    with_waiting_scan(project) do
      expect do
        with_lock_deadline { scanner(project, -> { raise PgHeroScanInterrupted }).call }
      end.to raise_error(ActiveRecord::LockWaitTimeout)
    end
  end

  # @spec RAILS-CONTROL-PLANE-039
  it "allows another project's scan to enter collection independently" do
    other = lock_model.create!(id: project.id + 1, name: "other")
    with_waiting_scan(project) do
      expect do
        with_lock_deadline { scanner(other, -> { raise PgHeroScanInterrupted }).call }
      end.to raise_error(PgHeroScanInterrupted)
    end
  end

  # @spec RAILS-CONTROL-PLANE-039
  it "releases scan exclusion after failure" do
    with_waiting_scan(project) { }

    expect do
      with_lock_deadline { scanner(project, -> { raise PgHeroScanInterrupted }).call }
    end.to raise_error(PgHeroScanInterrupted)
  end

  # @spec RAILS-CONTROL-PLANE-039
  it "retains the dirty-record guard without discarding caller changes" do
    project.name = "pending"

    expect { scanner(project, -> { raise PgHeroScanInterrupted }).call }.to raise_error(RuntimeError, /unpersisted changes/)
    expect(project.name).to eq("pending")
    expect(lock_model.find(project.id).name).to eq("before")
  end

  def scanner(target, collector)
    described_class.new(project: target, client: Object.new, environment: "development", collector: collector)
  end

  def with_lock_deadline
    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL lock_timeout = '100ms'")
      yield
    end
  end

  def with_waiting_scan(target)
    entered = Queue.new
    release = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |worker_connection|
        worker_project = lock_model.find(target.id)
        collector = lambda do
          entered << worker_connection.select_value("SELECT pg_backend_pid()")
          release.pop
          raise PgHeroScanInterrupted
        end
        scanner(worker_project, collector).call
      rescue PgHeroScanInterrupted
        nil
      end
    end
    worker_pid = Timeout.timeout(5) { entered.pop }
    expect(worker_pid).not_to eq(connection.select_value("SELECT pg_backend_pid()"))
    yield
  ensure
    release << true if release
    if worker
      Timeout.timeout(5) { worker.value }
    end
  end
end
