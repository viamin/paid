# frozen_string_literal: true

class NotificationRuleState < ApplicationRecord
  belongs_to :account
  belongs_to :subject, polymorphic: true

  validates :source, presence: true
end
