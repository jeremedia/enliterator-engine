# frozen_string_literal: true

# v-next: mark WHY a cycle ran. "scheduled" = the event-driven pacemaker (the
# default every existing row and every normal beat carries); "pulse" = a
# directed, targeted cycle (Heartbeat.pulse). Reversible; additive; a non-pulse
# host's rows and surfaces stay byte-identical (surfaces render a marker only
# when trigger == "pulse").
class AddTriggerToEnliteratorHeartbeats < ActiveRecord::Migration[8.1]
  def change
    add_column :enliterator_heartbeats, :trigger, :string, null: false, default: "scheduled"
  end
end
