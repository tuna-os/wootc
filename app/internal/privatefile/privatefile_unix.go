//go:build !windows

package privatefile

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

func open(path string, exclusive bool) (*os.File, error) {
	flags := unix.O_WRONLY | unix.O_CREAT | unix.O_CLOEXEC | unix.O_NOFOLLOW | unix.O_NONBLOCK
	if exclusive {
		flags |= unix.O_EXCL
	}
	fd, err := unix.Open(path, flags, 0o600)
	if err != nil {
		return nil, pathError(path, err)
	}
	f := os.NewFile(uintptr(fd), path)
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return nil, pathError(path, errors.Join(err, f.Close()))
	}
	if st.Mode&unix.S_IFMT != unix.S_IFREG || st.Mode&0o077 != 0 || st.Uid != uint32(os.Geteuid()) {
		err := fmt.Errorf("existing file is not private to the current user")
		return nil, pathError(path, errors.Join(err, f.Close()))
	}
	return f, nil
}
