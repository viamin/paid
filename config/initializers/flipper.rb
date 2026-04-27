# frozen_string_literal: true

adapter = Flipper::Adapters::ActiveRecord.new
flipper = Flipper.new(adapter)

Rails.configuration.x.feature_flags ||= ActiveSupport::OrderedOptions.new
Rails.configuration.x.feature_flags.flipper = flipper
