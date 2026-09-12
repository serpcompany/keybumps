# Window-control sanitized trace

`chrome-green-captured-sanitized-trace.json` uses the value-only format built by
the production `StandardWindowControlMonitor` and replayed through its production
`WindowControlActionDetector`. The fixture records Chrome adapter identity, live
shortcut metadata, and state-transition booleans without private window or
document titles, contents, pointer coordinates, PIDs, or tokens.

The fixture proves the sanitized capture/replay seam and the app-specific green
policy. It does not claim that the previously failing physical Accessibility run
now passes; integrated HID acceptance remains required after the permission
runtime repair lands.
