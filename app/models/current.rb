# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :account, :user, :request_id
end
