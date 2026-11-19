// Package privatefile writes confidential files without publishing bytes before
// access is restricted. Existing files must already be private: writes neither
// repair their permissions nor bypass the caller's directory-trust checks.
package privatefile

import (
	"errors"
	"os"
)

// WriteFile creates a private file or truncates an already-private file in place.
// It deliberately has the same non-atomic publication contract as os.WriteFile.
func WriteFile(path string, data []byte) error {
	return write(path, data, false)
}

// WriteNew creates a private file exclusively, never replacing an existing name.
func WriteNew(path string, data []byte) error {
	return write(path, data, true)
}

func write(path string, data []byte, exclusive bool) error {
	f, err := open(path, exclusive)
	if err != nil {
		return err
	}
	if !exclusive {
		if err := f.Truncate(0); err != nil {
			return errors.Join(err, f.Close())
		}
	}
	_, err = f.Write(data)
	return errors.Join(err, f.Close())
}

func pathError(path string, err error) error {
	return &os.PathError{Op: "open private file", Path: path, Err: err}
}
