# frozen_string_literal: true

module Automation
  module Providers
    module Data
      Attachment = ::Data.define(:id, :name, :content_type, :url, :raw)
    end
  end
end
