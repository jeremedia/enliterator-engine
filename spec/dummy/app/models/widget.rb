# Dummy host model for the engine test suite. Becomes Tendable by including the
# concern; defines to_enliterator_text so the Tendable default picks it up.
class Widget < ApplicationRecord
  include Enliterator::Tendable

  def to_enliterator_text
    [ title, body ].compact.join("\n")
  end
end
