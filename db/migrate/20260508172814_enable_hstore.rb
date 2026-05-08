# frozen_string_literal: true

class EnableHstore < ActiveRecord::Migration[8.1]
  def change
    enable_extension :hstore
  end
end
