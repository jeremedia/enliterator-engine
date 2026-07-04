# Dummy WHOLE for the v0.56 topology suite: a Book groups Widgets
# (widgets.book_id). Deliberately NOT Tendable — a whole need not be one
# (topology and synthesized_tendables are orthogonal); the bridge-warning spec
# uses Widget (which IS Tendable) as a whole to exercise the warning.
class Book < ApplicationRecord
end
