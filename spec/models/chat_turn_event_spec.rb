# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurnEvent do
  it { is_expected.to belong_to(:chat_turn) }
  it { is_expected.to validate_presence_of(:event_type) }
end
