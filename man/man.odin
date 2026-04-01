package man

import "core:os"
import "core:io"
import "core:strings"
import "core:fmt"
import "core:unicode/utf8"
import s "core:text/scanner"

COMMENT_LITS :: " /*\n"

write_header :: proc(w: io.Writer, title: string, date: string, collection: string, version: string) -> io.Error {
  werr: io.Error
  _ = io.write_string(w, ".TH ODIN_") or_return
  _ = io.write_string(w, title) or_return
  _ = io.write_string(w, " 3 \"") or_return
  _ = io.write_string(w, date) or_return
  _ = io.write_string(w, "\" \"") or_return
  _ = io.write_string(w, version) or_return
  _ = io.write_string(w, "\" \"") or_return 
  _ = io.write_string(w, collection) or_return
  _ = io.write_string(w, "\"\n\n.SH NAME\n") or_return
  return nil
}

read_parse_and_write_description_and_declarations_from_path :: proc(w: io.Writer, path: string) {
  job_alloc := context.temp_allocator
  defer free_all(job_alloc)
  data, ferr := os.read_entire_file(path, job_alloc)
  if ferr != nil {
    fmt.println("failed to read file:", path, "error:", ferr)
    return
  }

  s: Scanner
  init_scanner(&s, data)
  parse_and_write_package_description(w, &s)
  parse_and_write_declarations(w, &s)
}

read_parse_and_write_description_and_declarations_from_file :: proc(w: io.Writer, fp: ^os.File) {
  job_alloc := context.temp_allocator
  defer free_all(job_alloc)
  data, ferr := os.read_entire_file(fp, job_alloc)
  if ferr != nil {
    fmt.println("failed to read file error:", ferr)
    return
  }

  s: Scanner
  init_scanner(&s, data)
  parse_and_write_package_description(w, &s)
  parse_and_write_declarations(w, &s)
}

read_parse_and_write_description_and_declarations :: proc {
  read_parse_and_write_description_and_declarations_from_file,
  read_parse_and_write_description_and_declarations_from_path,
}

read_parse_and_write_declarations_from_path :: proc(w: io.Writer, path: string) {
  job_alloc := context.temp_allocator
  defer free_all(job_alloc)
  data, ferr := os.read_entire_file(path, job_alloc)
  if ferr != nil {
    fmt.println("failed to read file:", path, "error:", ferr)
    return
  }

  s: Scanner
  init_scanner(&s, data)
  parse_and_write_declarations(w, &s)
}

Scanner :: s.Scanner

init_scanner :: proc(h: ^Scanner, data: []byte) {
  s.init(h, string(data), "")
  h.flags = s.Odin_Like_Tokens ~ {.Skip_Comments}
}

Parse_Flag :: enum u32 {
  Scanning_Body,
  Writting_Comm,
}
Parse_Flags :: distinct bit_set[Parse_Flag; u32]

parse_and_write_package_description :: proc(w: io.Writer, h: ^s.Scanner) {
  werr: io.Error

  {
    tok: rune
    if tok = s.scan(h); tok == s.EOF {
      fmt.println("unexpected end of file in the begging")
      return
    }
    if tok == s.Comment {
      text := s.token_text(h)
      text = strings.trim(text, COMMENT_LITS)
      if _, werr = io.write_string(w, "odin strings \\- "); werr != nil do return
      if _, werr = write_without(w, text, "`"); werr != nil do return
    }
  }
  if _, werr = io.write_string(w, "\n\n.SH SYNOPSIS\n.B import \\&\"core:strings\"\n\n.SH DECLARATIONS\n\n"); werr != nil do return
}

parse_and_write_declarations :: proc(w: io.Writer, h: ^s.Scanner) {
  werr: io.Error

  {
    tok := s.scan(h)
    for {
      if tok != '#' do break
      if s.scan(h) != '+' do break
      if s.scan(h) != s.Ident do break
      if s.token_text(h) == "private" do return
    }
  }

  Token :: struct {
    tok: rune,
    text: string,
    pos: int,
    end: int,
  }

  rb_len :: 8
  Ring_Buffer :: struct {
    data: [rb_len]Token,
    head: uint,
  }

  rb_push :: proc "contextless" (b: ^Ring_Buffer, t: Token) {
    b.data[b.head & (rb_len-1)] = t
    b.head += 1
  }

  rb_peek :: proc "contextless" (b: ^Ring_Buffer, offset: int) -> Token {
    return b.data[uint(int(b.head)+offset) & (rb_len-1)]
  }

  rb_token_is :: proc "contextless" (b: ^Ring_Buffer, offset: int, r: rune) -> bool {
    old_t := rb_peek(b, offset)
    return old_t.tok == r 
  }
  rb_text_is ::  proc "contextless" (b: ^Ring_Buffer, offset: int, str: string) -> bool {
    old_t := rb_peek(b, offset)
    return old_t.text == str 
  }

  rb: Ring_Buffer
  t: Token

  comment: string
  beg_decl: int
  flags: Parse_Flags

  parsing_stage := 0
  scope_level := 0

  // START :: 0
  // END :: START + 5
  i := 0
  for {
    t.tok = s.scan(h)
    t.text = s.token_text(h)
    t.pos = h.tok_pos
    t.end = h.tok_end
    if t.tok == s.EOF do break
    // if i >= START && i < END do fmt.println(i, ":", t.text)

    // theoretically we should not get it in strings, but we need still to check
    // that and also in chars
    switch t.tok {
    case '{': scope_level += 1
    case '}': scope_level -= 1
    }


    SEARCHING_DECL ::  0
    SCANNING_KEYW  ::  1
    CHECKING_BODY  ::  2
    SCANNING_DECL  ::  3
    switch parsing_stage {
    case SEARCHING_DECL:
      // if i >= START && i < END do fmt.println("SEARCHING_DECL")
      if t.tok == ':' && rb_peek(&rb, -1).tok == ':' && scope_level == 0 {
        if (rb_token_is(&rb, -4, '@') && rb_text_is(&rb, -3, "private")) ||
           (rb_token_is(&rb, -6, '@') && rb_text_is(&rb, -4, "private")) {
          continue
        }

        old_t := rb_peek(&rb, -2)
        beg_decl = old_t.pos

        if old_t := rb_peek(&rb, -3); old_t.tok == s.Comment {
          comment = old_t.text
          flags |= {.Writting_Comm}
        }
        parsing_stage = SCANNING_KEYW
      }
    case SCANNING_KEYW:
      // if i >= START && i < END do fmt.println("SCANNING_KEYW")
      if t.text == "proc" || t.text == "struct" {
        parsing_stage = CHECKING_BODY
      } else {
        if h.src[t.end] == '\n' {
          werr = write_decl(w, string(h.src[beg_decl:t.end]), comment, flags)
          if werr != nil do return
          parsing_stage = SEARCHING_DECL
          continue
        }
        parsing_stage = SCANNING_DECL
      }
    case CHECKING_BODY:
      // if i >= START && i < END do fmt.println("CHECKING_BODY")
      if t.tok == '{' {
        flags |= {.Scanning_Body}
      }
      parsing_stage = SCANNING_DECL

    case SCANNING_DECL:
      // if i >= START && i < END do fmt.println("SCANNING_DECL")
      decl_str: string

      if .Scanning_Body in flags {
        if t.tok == '}' && scope_level == 0 { 
          // if i >= START && i < END do fmt.println("scanning body")
          decl_str = string(h.src[beg_decl:t.pos+1])
          if old_t := rb_peek(&rb, -1); old_t.tok == ',' {
            raw_data(h.src)[old_t.pos] = ' '
          }
          replace_char(decl_str, '\t', ' ')
        }
      } else {
        if t.end < len(h.src) && h.src[t.end] == '\n' {
          // if i >= START && i < END do fmt.println("scanning til end of line")
          if t.tok == '{' {
            decl_str = string(h.src[beg_decl:t.pos])
          } else {
            decl_str = string(h.src[beg_decl:t.end])
          }
        }
      }

      if len(decl_str) != 0 {
        // if i >= START && i < END do fmt.println("writing declaration")
        werr = write_decl(w, decl_str, comment, flags)
        if werr != nil do return
        flags = {}
        parsing_stage = SEARCHING_DECL
      }
    }

    rb_push(&rb, t)
    i += 1
  }
}

write_decl :: proc(w: io.Writer, decl_str: string, comment: string, flags: Parse_Flags) -> io.Error {
  _ = io.write_string(w, ".B \\&") or_return
  _ = write_without(w, decl_str, "\n") or_return
  if .Writting_Comm in flags {
    trimmed := strings.trim(comment, COMMENT_LITS)
    c_end := strings.index_byte(trimmed, '\n')

    _ = io.write_string(w, "\n.sp -1\n.IP\n") or_return
    if c_end != -1 {
      _ = io.write_string(w, trimmed[:c_end]) or_return
    } else {
      _ = io.write_string(w, trimmed) or_return
    }
    _ = io.write_string(w, "\n.PP\n") or_return
  } else {
     _ = io.write_string(w, "\n\n") or_return
  }
  return nil
}

@private
replace_char :: proc(s: string, old: byte, new: byte) {
  b := transmute([]byte)(s)
  for i := 0; i < len(b); i += 1 {
    if b[i] == old do b[i] = new
  }
}

@private
write_without :: proc(w: io.Writer, s: string, skip: string) -> (n: int, err: io.Error) {
  start: int
  for r, end in s {
    if strings.contains_rune(skip, r) {
      if start < end {
        n += io.write_string(w, s[start:end]) or_return
      }
      start = end+utf8.rune_size(r)
    }
  }
  if start < len(s) {
    n += io.write_string(w, s[start:]) or_return
  }
  return
}
