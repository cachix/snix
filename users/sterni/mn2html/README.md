# mn2html

Convert mail notes authored e.g. by the iOS/macOS Notes application,
into HTML suitable for standard browsers. Instead of full documents,
mn2html emits HTML fragments that can easily be embedded into other
documents or postprocessed using a templating engine.

## History

mn2html is a reimplementation mnote-html from //users/sterni/mblog.
The reason for this was mainly avoiding the startup cost associated
with Common Lisp programs, so the program would be suitable for
shell scripting.

## Tasks

- [ ] Properly handle `text/plain` bodies (from e.g. notemap)
- [ ] Add man page
- [ ] Help screen
- [ ] Improve error reporting
