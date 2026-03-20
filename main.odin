package main

import "core:strings"
import "core:fmt"
import "core:bufio"
import "core:io"
import "core:path/filepath"
import "core:path/slashpath"
import "core:os"
import s "core:text/scanner"
import "core:unicode/utf8"
import "core:flags"
import "core:time"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"
import "core:log"

COMMENT_LITS :: " /*\n"

to_upper_char :: proc(c: ^u8) {
  if 'a' <= c^ && c^ <= 'z' {
    c^ -= 'a'-'A'
  }
}

to_upper :: proc(s: []u8) {
  for i := 0; i < len(s); i += 1 {
    to_upper_char(&s[i])
  }
}

replace_char :: proc(s: string, old: byte, new: byte) {
  b := transmute([]byte)(s)
  for i := 0; i < len(b); i += 1 {
    if b[i] == old do b[i] = new
  }
}

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

Parse_Flag :: enum u32 {
  Scanning_Body,
  Writting_Comm,
}
Parse_Flags :: distinct bit_set[Parse_Flag; u32]

Options :: struct {
  path: string `args:"pos=0" usage:"Target directory or file. Current working directory is default."`,
}

main :: proc() {
  main_arena: virtual.Arena
  arena_err := virtual.arena_init_growing(&main_arena)
  if arena_err != nil {
    fmt.println("error initiating arena:", arena_err)
    return
  }
  defer virtual.arena_destroy(&main_arena)
  context.allocator = virtual.arena_allocator(&main_arena)

  file_content: []byte
  target_path: string
  collection_name: string
  subpath: string

  opt: Options

  flags.parse_or_exit(&opt, os.args, .Odin)

  if opt.path == "" {
    os_err: os.Error
    target_path, os_err = os.get_working_directory(context.temp_allocator)
    if os_err != nil {
      fmt.println("Cannot get current working directory path, please provide a target directory or file")
      return
    }
  } else {
    if sep := strings.index_rune(opt.path, ':'); sep >= 0 {
      state, stdout, _, err := os.process_exec({ command = {"odin", "root"} }, context.temp_allocator)
      if !state.success || err != nil {
        fmt.println("Cannot get directory by calling `odin root`. Please write a complete path")
        fmt.println("Error:", err)
        return
      }
      odin_path := string(stdout)
      collection_name = opt.path[:sep]
      subpath = opt.path[sep+1:]
      
      target_path = slashpath.join({odin_path, collection_name, subpath})
    } else {
      target_path = opt.path
    }
  }

  fmt.println("we are getting path:", target_path)

  root_file, open_err := os.open(target_path)
  if open_err != nil {
    fmt.println("failed to open path:", target_path)
    return
  }
  defer os.close(root_file)
  root_info, stat_err := os.fstat(root_file, context.temp_allocator)
  if stat_err != nil {
    fmt.println("failed to get path info:", target_path)
  }

  year, month, _ := time.date(time.now())

  date := strings.concatenate({reflect.enum_string(month), fmt.aprint(year)})
  title: string
  collection: string
  version: string
  w: io.Writer

  #partial switch root_info.type {
  case .Directory:
  case .Regular:
    size, werr := os.file_size(root_file)
    if werr != nil {
      fmt.println("can't get root file size:", werr)
      return
    }

    file_content = make([]byte, size)
    _, _ = os.read(root_file, file_content)

    filename := filepath.base(target_path)
    outpath := strings.concatenate({filename, ".3"})

    fmt.println("outpath:", outpath)
    fp, ferr := os.open(outpath, os.O_WRONLY|os.O_CREATE)
    buf: [1024]byte
    buf_writer: bufio.Writer
    bufio.writer_init_with_buf(&buf_writer, os.to_stream(fp), buf[:]) 
    w = bufio.writer_to_writer(&buf_writer)

    title := strings.concatenate({filename, "_FILE"});
    to_upper(transmute([]u8)(title))

    if collection_name == "" {
      collection = "Odin Code Documentation"
    } else {
      to_upper_char(raw_data(collection_name))
      collection = strings.concatenate({"Odin Collection ", collection_name});
    }

    state, stdout, _, err := os.process_exec({ command = {"odin", "root"} }, context.allocator)
    if !state.success || err != nil {
      fmt.println("Cannot get directory by calling `odin root`. Please write a complete path")
      fmt.println("Error:", err)
      return
    }
    version = string(stdout)
  case:
    fmt.println("unsupported file type")
  }

  defer io.flush(w)
  werr := write_header(w, title, date, collection, version)
  if werr != nil {
    fmt.println("failed to write header:", werr)
    return
  }

  h: s.Scanner
  s.init(&h, string(file_content), "")
  h.flags = s.Odin_Like_Tokens ~ {.Skip_Comments}
  parse_and_write_package_description(w, &h)
  parse_and_write_declarations(w, &h)

}

write_header :: proc(w: io.Writer, title: string, date: string, collection: string, version: string) -> io.Error {
  pack_str := "STRINGS"
  date_str := "March 2026"
  vers_str := "dev-2026-03"
  coll_str := "Core"

  werr: io.Error
  _ = io.write_string(w, ".TH ODIN_") or_return
  _ = io.write_string(w, pack_str) or_return
  _ = io.write_string(w, " 3 \"") or_return
  _ = io.write_string(w, date_str) or_return
  _ = io.write_string(w, "\" \"") or_return
  _ = io.write_string(w, vers_str) or_return
  _ = io.write_string(w, "\" \"Odin Collection ") or_return
  _ = io.write_string(w, coll_str) or_return
  _ = io.write_string(w, "\"\n\n.SH NAME\n") or_return
  return nil
}

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

  // file comment
  // for {
  //     if tok = s.scan(h); tok == s.EOF {
  //         fmt.println("unexpected end of file in the begging")
  //         return
  //     }
  //     if tok != s.Comment {
  //         break;
  //     }
  //
  //     text := s.token_text(h)
  //     text = strings.trim(text, " /*")
  // }
}

parse_and_write_declarations :: proc(w: io.Writer, h: ^s.Scanner) {
  werr: io.Error
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

  // START :: 2600
  // END :: START + 2000
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

    SEARCHING_DECL :: 0
    SCANNING_KEYW  :: 1
    CHECKING_BODY  :: 2
    SCANNING_DECL  :: 3
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
        if h.src[t.end] == '\n' {
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
