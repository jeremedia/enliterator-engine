# Dummy host model for the engine test suite. Becomes Tendable by including the
# concern; defines to_enliterator_text so the Tendable default picks it up.
class Widget < ApplicationRecord
  include Enliterator::Tendable

  def to_enliterator_text
    [ title, body ].compact.join("\n")
  end

  # v0.25: the parts contract — sections split on markdown h2 headings; a
  # body without headings yields one unnamed section; blank body yields none.
  def to_enliterator_parts
    return [] if body.blank?
    body.split(/^(?=## )/m).reject(&:blank?).map do |chunk|
      { heading: chunk[/\A## (.+)$/, 1], text: chunk.strip }
    end
  end
end
