//go:build !linux

package slurp

import "errors"

// The offline pipeline only runs on Linux; elsewhere there is no scratch
// budget, so ExtractData copies nothing.
func statfsAvailable(string) (int64, error) {
	return 0, errors.New("scratch capacity is only observed on Linux")
}
