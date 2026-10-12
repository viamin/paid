# frozen_string_literal: true

require "rails_helper"

CommitteeMiddlewareStack = Class.new do
  attr_reader :entries

  def initialize
    @entries = []
  end

  def insert_after(*args, **options)
    entries << { args:, options: }
  end
end unless defined?(CommitteeMiddlewareStack)

CommitteeInitializer = Class.new unless defined?(CommitteeInitializer)

RSpec.describe CommitteeInitializer, :no_db do
  let(:project_root) { Pathname.new(__dir__).join("..", "..").expand_path }
  let(:initializer_path) { project_root.join("config/initializers/committee.rb") }
  let(:middleware) { CommitteeMiddlewareStack.new }
  let(:config) { Struct.new(:middleware).new(middleware) }
  let(:application) { Struct.new(:config, :root).new(config, project_root) }

  before do
    allow(Rails).to receive_messages(application:, root: project_root)
    allow(Rails.logger).to receive(:warn)
  end

  # @spec MOBILE-API-016
  it "raises strict validation failures in test" do
    load_initializer("test")

    expect(middleware.entries.map { |entry| entry[:args].first }).to all(eq(Rack::Sendfile))
    expect(middleware.entries.map { |entry| entry[:options].slice(:strict, :raise, :ignore_error) })
      .to all(eq(strict: true, raise: true, ignore_error: false))
  end

  # @spec MOBILE-API-016
  it "warns and continues after validation failures outside test" do
    load_initializer("development")

    middleware.entries.each do |entry|
      options = entry.fetch(:options)
      expect(options.slice(:strict, :raise, :ignore_error)).to eq(strict: false, raise: false, ignore_error: true)
      options.fetch(:error_handler).call(StandardError.new("schema mismatch"), "REQUEST_METHOD" => "GET", "PATH_INFO" => "/api/v1/probe")
    end

    expect(Rails.logger).to have_received(:warn).twice.with(
      message: "mobile_api.contract_validation_failed",
      error_class: "StandardError",
      error_message: "schema mismatch",
      request_method: "GET",
      request_path: "/api/v1/probe"
    )
  end

  private

  def load_initializer(environment)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(environment))

    load initializer_path
  end
end
