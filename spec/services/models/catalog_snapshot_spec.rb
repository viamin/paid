# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Models::CatalogSnapshot do
  self.use_transactional_tests = false

  # @spec MODEL-AVAILABILITY-008
  it "blocks a shared catalog read until an exclusive refresh commits" do
    release_refresh = Queue.new
    refresh_thread = hold_lock(:refresh, release_refresh)
    read_thread, reader_pid, read_finished = start_consistent_read

    expect(waiting_for_advisory_lock?(reader_pid)).to be(true)
    expect(read_finished).to be_empty

    release_refresh << true
    expect(Timeout.timeout(5) { read_finished.pop }).to eq(:resolved)
  ensure
    release_refresh&.push(true) if refresh_thread&.alive?
    refresh_thread&.join
    read_thread&.join
  end

  # @spec MODEL-AVAILABILITY-008
  it "allows shared catalog reads to coexist" do
    release_first_read = Queue.new
    first_read = hold_lock(:consistent_read, release_first_read)
    second_read, _pid, second_read_finished = start_consistent_read

    expect(Timeout.timeout(5) { second_read_finished.pop }).to eq(:resolved)
  ensure
    release_first_read&.push(true) if first_read&.alive?
    first_read&.join
    second_read&.join
  end

  def hold_lock(lock_method, release)
    locked = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.public_send(lock_method) do
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(5) { locked.pop }
    thread
  end

  def start_consistent_read
    started = Queue.new
    finished = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        started << connection.select_value("SELECT pg_backend_pid()")
        finished << described_class.consistent_read { :resolved }
      end
    end
    [ thread, Timeout.timeout(5) { started.pop }, finished ]
  end

  def waiting_for_advisory_lock?(pid)
    Timeout.timeout(5) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks
            WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted
          )
        SQL
        return true if waiting

        Thread.pass
      end
    end
  end
end
