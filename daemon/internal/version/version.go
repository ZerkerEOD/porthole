// Package version holds build information set via -ldflags.
package version

// Version is the semantic version or git describe output.
var Version = "dev"

// Protocol is the wire protocol major version the app must match.
const Protocol = 1
