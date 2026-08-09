#MAN-ODIN

`Manual Page` generator for odin code from comments.

Status: works mostly correctly, program may include some private declarations
and some descriptions maybe absent or incomplete.

Remark: you can achieve a similar functionality with official `odin doc <path> | less`
and you can add `-short`. It is not man page generation, but that way you are
currently getting the same information, if not more.

Licence: You are free to copy, modify and contribute to this codebase.

## Features
Takes the first line of a comment at the top of the file as a file description, 
for packages the top line is taken from a file matching the package name.
Uses the first line of comment above declarations as their description.
Writes declarations and descriptions to `odin_<packagename>.3` for packages and
to `odin_<filename>_file.3` for file. Declarations marked  with `private` are
ignored, although the logic for detection of private declarations is not complete.

+ `man` - a package with procedures to generate man pages
+ `man-odin <path>` - generates documentation for a package or a file in the path
    and outputs it into `/usr/local/share/man/man3`. You may need to run it as
    root, i.e. with sudo, as a necessity for writing privileges
+ `man-odin core:<path>` - generates documentation for `<path>` from `$(odin root)/core`
    (or for a different collection, like `vendor` or `base`)
+ `man-odin <path> -out:<outpath>` - sets a custom output path
+ `man-odin -all-collections` - generates man pages for the entire stadard library

e.g., `sudo man-odin core:strings && man odin_strings` gives
![screenshot](http://potoshin.com/images/man_odin_image.png)

## Raison d'Être
I found searching the Odin standard library to be somewhat inefficient. The
website isn't the most ergonomic, and the source code can be quite verbose. To
solve this, I wrote an utility that generates man pages for a package. It
extracts top-level definitions from every file along with a one-line
description, producing a compact man file for quick browsing. Further
inspection can then be done directly in the source code. It is more verbose than
`odin doc -short` and more compact than `odin doc`.

## Implementation Details
Initially, I intended to generate man pages from odin-doc files, but I found
the current implementation being incomplete and lacking active maintenance [is
it still true?]. Instead, `man-odin` uses `core:text/scanner` to traverse the
source and identify patterns. The architecture is a finite automaton utilizing
a ring buffer for token history. Finally, the man page encoding is streamed
directly to a file via a buffered writer.

P.S. I found out that there is `odin doc` command, so it may be more reasonable
to rely on it in the future.

## Future Outlook
While a more ambitious goal would be the generation of a complete offline
documentation, not only of the standard library, that currently remains out of
the scope for this project.

## TODO
* core:os process_exec :: proc(    desc: Process_Desc,
* string "" literals
* test cases coverege
+ write how to import the package for base:runtime
+ stdin in os and as a separate manpage
+ include synapsys for odin_os
+ no trimming of newline if there are comments in the declaration
