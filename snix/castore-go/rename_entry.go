package castorev1

// RenamedEntry returns an entry with a new name.
func RenamedEntry(entry *Entry, name string) *Entry {
	if directoryEntry := entry.GetDirectory(); directoryEntry != nil {
		return &Entry{
			Entry: &Entry_Directory{
				Directory: &DirectoryEntry{
					Name:   []byte(name),
					Digest: directoryEntry.GetDigest(),
					Size:   directoryEntry.GetSize(),
				},
			},
		}
	} else if fileEntry := entry.GetFile(); fileEntry != nil {
		return &Entry{
			Entry: &Entry_File{
				File: &FileEntry{
					Name:       []byte(name),
					Digest:     fileEntry.GetDigest(),
					Size:       fileEntry.GetSize(),
					Executable: fileEntry.GetExecutable(),
				},
			},
		}
	} else if symlinkEntry := entry.GetSymlink(); symlinkEntry != nil {
		return &Entry{
			Entry: &Entry_Symlink{
				Symlink: &SymlinkEntry{
					Name:   []byte(name),
					Target: symlinkEntry.GetTarget(),
				},
			},
		}
	} else {
		panic("unreachable")
	}
}
