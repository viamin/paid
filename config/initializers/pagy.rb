# frozen_string_literal: true

# Pagy pagination defaults
# See https://ddnexus.github.io/pagy/

# Pagy 9 renamed :items to :limit
Pagy::DEFAULT[:limit] = 25
