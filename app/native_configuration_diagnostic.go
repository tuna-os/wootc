package main

import "errors"

// The server selects this projection only for the failing current configuration
// request. It cannot establish configuration success or install authority.
func nativeConfigurationFailureData(err error) any {
	var failure interface{ nativeConfigurationDiagnostic() any }
	if errors.As(err, &failure) {
		return failure.nativeConfigurationDiagnostic()
	}
	return nil
}
