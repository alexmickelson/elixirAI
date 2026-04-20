package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// exitOnError prints the error message to stderr and exits if err is non-nil.
func exitOnError(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %s\n", err)
		os.Exit(1)
	}
}

// exitWithError formats and prints an error message, then exits.
func exitWithError(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}

// isHelpFlag returns true if the argument is a help flag.
func isHelpFlag(arg string) bool {
	return arg == "--help" || arg == "-h" || arg == "help"
}

// parseKeyValueArgs converts a list of "key=value" strings into a map.
// Values are auto-typed: integers, floats, and booleans are preserved
// as their native types; everything else becomes a string.
func parseKeyValueArgs(pairs []string) map[string]interface{} {
	result := make(map[string]interface{})

	for _, pair := range pairs {
		separatorIdx := strings.IndexByte(pair, '=')
		if separatorIdx < 0 {
			exitWithError("invalid argument (expected key=value): %s", pair)
		}
		key := pair[:separatorIdx]
		value := pair[separatorIdx+1:]

		// Try integer
		if intValue, err := strconv.ParseInt(value, 10, 64); err == nil && !strings.Contains(value, ".") {
			result[key] = intValue
			continue
		}

		// Try float
		if floatValue, err := strconv.ParseFloat(value, 64); err == nil {
			result[key] = floatValue
			continue
		}

		// Try boolean
		switch value {
		case "true":
			result[key] = true
			continue
		case "false":
			result[key] = false
			continue
		}

		// Default to string
		result[key] = value
	}
	return result
}
