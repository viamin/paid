# frozen_string_literal: true

require "rails_helper"
require "timeout"
require "solid_cable"

RSpec.describe ActionCable::SubscriptionAdapter::SolidCable, :no_db do
  let(:interlock) { ActiveSupport::Dependencies::Interlock.new }
  let(:writes) { Queue.new }
  let(:server) do
    ActionCable::Server::Base.new(config: ActionCable::Server::Configuration.new).tap do |instance|
      instance.config.cable = { "adapter" => "solid_cable" }
    end
  end

  before do
    reload_interlock = interlock
    allow(ActiveSupport::Dependencies).to receive(:interlock).and_return(interlock)
    executor = Class.new(ActiveSupport::Executor)
    hook = Object.new
    hook.define_singleton_method(:run) { reload_interlock.start_running }
    hook.define_singleton_method(:complete) { |_| reload_interlock.done_running }
    executor.register_hook(hook)
    allow(Rails.application).to receive(:executor).and_return(executor)

    # Replace only the external adapter's database boundary. Its threads,
    # shutdown, executor and Rails unload interlock remain real.
    recorded_writes = writes
    database = Class.new
    database.define_singleton_method(:maximum) { |_| 0 }
    database.define_singleton_method(:broadcastable) { |*| [] }
    database.define_singleton_method(:broadcast) { |channel, payload| recorded_writes << [ channel, payload ] }
    database.define_singleton_method(:broadcast_batch) do |batch|
      batch.each { |message| recorded_writes << [ message.channel, message.payload ] }
    end
    stub_const("SolidCable::Message", database)
    allow(SolidCable).to receive(:autotrim?).and_return(false)
  end

  # @spec RAILS-CONTROL-PLANE-009
  it "finishes shutdown under the unload lock and preserves broadcasts across restart" do
    adapter = described_class.new(server)
    Timeout.timeout(3) do
      interlock.unloading do
        adapter.broadcast("reload-test", "before")
        adapter.shutdown
      end
    end
    expect(writes.pop(timeout: 3)).to eq([ "reload-test", "before" ])

    adapter = described_class.new(server)
    adapter.broadcast("reload-test", "after")
    expect(writes.pop(timeout: 3)).to eq([ "reload-test", "after" ])
  ensure
    # The unload lock has been released even on failure, so writers can exit.
    Timeout.timeout(3) { adapter.shutdown }
  end
end
