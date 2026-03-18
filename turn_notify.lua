-- Turn notification script
-- Calls turn_notify.sh on each turn change to email players

function turn_notify_callback(turn, year)
  log.normal(string.format("Turn %d (Year %d) started, sending notifications...", turn, year))
  os.execute(string.format("/opt/freeciv/turn_notify.sh %d %d &", turn, year))
  return false
end

signal.connect("turn_begin", "turn_notify_callback")
