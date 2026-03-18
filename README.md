# MAN-ODIN

Manual page generator for odin code from comments

## Raison d'Être
I found searching the Odin standard library to be somewhat inefficient. The
website isn't the most ergonomic, and the source code can be quite verbose. To
solve this, I wrote a utility that generates man pages for the library. It
extracts top-level definitions from every file along with a one-line
description, producing a compact man file for quick browsing. Further
inspection can then be done directly in the source code.

## Features

## Implementation Details
Initially, I intended to generate man pages from odin-doc files, but the
current implementation is incomplete and lacks active maintenance. Instead,
`man-odin` uses `core:text/scanner` to traverse the source and identify
patterns. The architecture is a finite automaton utilizing a ring buffer for
token history. Finally, the man page encoding is streamed directly to a file
via a buffered writer.

## Future Outlook
While a more ambitious goal would be the generation of complete offline
documentation, that currently remains out of scope for this project.
