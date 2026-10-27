# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::CatalogSnapshot do
  # @spec MODEL-AVAILABILITY-008
  it "does not allow a resolver to read between catalog seeding and availability reconciliation" do
    refresher, release_refresh = start_refresh
    reader, reader_finished = start_reader
    expect { Timeout.timeout(0.2) { reader_finished.pop } }.to raise_error(Timeout::Error)

    release_refresh << true
    refresher.join
    expect { Timeout.timeout(1) { reader_finished.pop } }.not_to raise_error
    reader.join
  ensure
    finish_threads(refresher, release_refresh, reader)
  end

  def start_refresh
    started = Queue.new
    release = Queue.new
    thread = Thread.new { with_connection { described_class.refresh { started << true; release.pop } } }
    started.pop
    [ thread, release ]
  end

  def start_reader
    finished = Queue.new
    thread = Thread.new { with_connection { described_class.read { finished << true } } }
    [ thread, finished ]
  end

  def finish_threads(refresher, release_refresh, reader)
    release_refresh << true if refresher&.alive?
    refresher&.join
    reader&.join
  end

  def with_connection(&)
    ActiveRecord::Base.connection_pool.with_connection(&)
  end
end
