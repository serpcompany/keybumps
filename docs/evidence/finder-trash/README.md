# Finder-to-Trash sanitized trace

`captured-sanitized-trace.json` is the value-only format emitted at the production
`DragDropActionDetector` boundary. The focused issue runner decodes and replays it
through that same detector and scans it for forbidden private fields.

The trace contains only allowlisted categories and booleans. It contains no file
name, path, URL, title, description, identifier, coordinates, PID, token, file ID,
or contents. This fixture proves the sanitized capture/replay seam; it does not
claim a successful physical Finder/Dock drag or replace integrated HID acceptance.
