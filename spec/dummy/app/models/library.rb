# Dummy ONE-ROW collection tendable for the v0.57 charter suite. A collection
# record must be a Tendable (claims live on it); declaring it via
# config.collection_tendable auto-joins the synthesized mask.
class Library < ApplicationRecord
  include Enliterator::Tendable

  def to_enliterator_text
    name.to_s
  end
end
