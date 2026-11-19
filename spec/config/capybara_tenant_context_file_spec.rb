# frozen_string_literal: true

require "rails_helper"

class CapybaraTenantContextFile < Pathname
end

RSpec.describe CapybaraTenantContextFile, :no_db do
  let(:worker) { ActionCable::Server::Worker.new(max_size: 1) }
  let(:connection) do
    logger = ActionCable::Connection::TaggedLoggerProxy.new(Rails.logger, tags: [])
    instance_double(ActionCable::Connection::Base, logger:)
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "installs exactly one wrapper around the finalized system-test Rack app" do
    wrapped_app = instance_double(Proc)
    allow(Capybara).to receive(:app) { wrapped_app }
    allow(Capybara).to receive(:app=) { |app| wrapped_app = app }

    CapybaraTenantContext.install!
    CapybaraTenantContext.install!

    expect(Capybara).to have_received(:app=).with(an_instance_of(CapybaraTenantContext)).once
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "initializes browser-server connections before Warden deserializes the session user" do
    app = instance_double(Proc)
    environment = { "PATH_INFO" => "/" }
    allow(app).to receive(:call).with(environment).and_return([ 200, {}, [] ])
    allow(TenantContext).to receive(:with_system_access).and_yield
    allow(TenantContext).to receive(:apply_system_access!)

    response = CapybaraTenantContext.new(app).call(environment)

    expect(response).to eq([ 200, {}, [] ])
    expect(TenantContext).to have_received(:with_system_access)
    expect(TenantContext).to have_received(:apply_system_access!)
    expect(app).to have_received(:call).with(environment)
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "does not mutate pooled session state for unrelated Rails executor work" do
    allow(TenantContext).to receive(:apply_system_access!)

    Rails.application.executor.wrap { }

    expect(TenantContext).not_to have_received(:apply_system_access!)
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "keeps Cable work outside a browser request's shared fixture session" do
    allow(TenantContext).to receive(:with_system_access).and_yield
    allow(TenantContext).to receive(:apply_system_access!)
    entered = Queue.new
    release = Queue.new
    attempted = Queue.new
    app = ->(_environment) { entered << true; release.pop; [ 200, {}, [] ] }
    request_thread = Thread.new { CapybaraTenantContext.new(app).call({}) }
    raise "Browser request did not start" unless entered.pop(timeout: 5)
    cable_thread = Thread.new do
      attempted << true
      worker.work(connection) { }
    end
    raise "Cable worker did not start" unless attempted.pop(timeout: 5)

    expect(cable_thread.join(0.2)).to be_nil
  ensure
    release << true if release
    request_thread&.join(5) || request_thread&.kill&.join
    cable_thread&.join(5) || cable_thread&.kill&.join
    worker&.halt
  end
end
