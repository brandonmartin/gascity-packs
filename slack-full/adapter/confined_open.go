package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// openBeneath opens rel (a Clean, root-relative path containing no
// "..") beneath rootAbs by walking one path component at a time: each
// step is an openat(2) relative to the fd of the already-opened parent,
// with O_NOFOLLOW set. The parent fd pins the verified directory inode,
// so a directory swapped for a symlink mid-walk cannot redirect the
// traversal — the userspace equivalent of openat2(RESOLVE_BENEATH),
// which stdlib syscall does not expose (and the adapter's
// zero-dependency go.mod keeps us from importing x/sys for).
//
// O_NOFOLLOW applies to every component, not just the leaf, so any
// symlink anywhere beneath root is a hard failure (ELOOP / ENOTDIR).
// That matches the caller's contract: realPath is EvalSymlinks-resolved
// before it gets here, so every component of a legitimate path is a
// real directory or file and the walk succeeds; only a mid-flight swap
// trips it.
func openBeneath(rootAbs, rel string) (*os.File, error) {
	if rel == "" || rel == "." || filepath.IsAbs(rel) {
		return nil, fmt.Errorf("openBeneath: invalid relative path %q", rel)
	}
	comps := strings.Split(filepath.Clean(rel), string(filepath.Separator))
	for _, c := range comps {
		if c == "" || c == "." || c == ".." {
			return nil, fmt.Errorf("openBeneath: invalid path component %q in %q", c, rel)
		}
	}
	dirFlags := syscall.O_RDONLY | syscall.O_DIRECTORY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	fd, err := syscall.Open(rootAbs, dirFlags, 0)
	if err != nil {
		return nil, fmt.Errorf("openBeneath: open root %q: %w", rootAbs, err)
	}
	for i, c := range comps {
		flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
		if i < len(comps)-1 {
			flags |= syscall.O_DIRECTORY
		}
		next, err := syscall.Openat(fd, c, flags, 0)
		syscall.Close(fd)
		if err != nil {
			return nil, fmt.Errorf("openBeneath: open component %q of %q: %w", c, rel, err)
		}
		fd = next
	}
	return os.NewFile(uintptr(fd), filepath.Join(rootAbs, rel)), nil
}
