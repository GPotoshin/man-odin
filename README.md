# MAN-ODIN

Manual page generator for odin code from comments

state: Code is partially working

## Features
Takes the first line of a comment at the top of the file as a file description, 
for packages the top line is taken from a file matching the package name.
Uses the first line of comment above declarations as their description.
Writes declarations and descriptions to `odin_<basename>.3` for packages and
to `odin_<basename>_file.3` for file. Declarations marked  with `private` are
ignored, although the logic for detection of private declarations is not complete.

+ `man` - package with procedures to generate man pages
+ `man-odin <path>` - generates documenetation for package or file in a path
+ `man-odin core:<path>` - generates documentation for `<path>` from odin root
+ `man-odin <path> -install` - installs man pages to `/usr/local/share/man/man3`
if such exists. You may need to run it as root.

## Raison d'Être
I found searching the Odin standard library to be somewhat inefficient. The
website isn't the most ergonomic, and the source code can be quite verbose. To
solve this, I wrote a utility that generates man pages for the library. It
extracts top-level definitions from every file along with a one-line
description, producing a compact man file for quick browsing. Further
inspection can then be done directly in the source code.

## Implementation Details
Initially, I intended to generate man pages from odin-doc files, but I fooound
the current implementation beeing incomplete and lacking active maintenance.
Instead, `man-odin` uses `core:text/scanner` to traverse the source and identify
patterns. The architecture is a finite automaton utilizing a ring buffer for
token history. Finally, the man page encoding is streamed directly to a file
via a buffered writer.

## Future Outlook
While a more ambitious goal would be the generation of complete offline
documentation, that currently remains out of scope for this project.
