package main

import "core:strings"
import "core:fmt"
import "core:bufio"
import "core:io"
import "core:path/filepath"
import "core:path/slashpath"
import "core:os"
import "core:unicode/utf8"
import "core:flags"
import "core:time"
import "core:reflect"
import "core:mem"
import "core:mem/virtual"
import "core:log"

import "man"

to_upper_char :: proc "contextless" (c: ^u8) {
  if 'a' <= c^ && c^ <= 'z' {
    c^ -= 'a'-'A'
  }
}

to_upper :: proc "contextless" (s: []u8) {
  for i := 0; i < len(s); i += 1 {
    to_upper_char(&s[i])
  }
}

Options :: struct {
  path: string `args:"pos=0" usage:"Target directory or file. Current working directory is default. Can be prefixed with collection"`,
  install: bool `name=install usage:"Searches for '/usr/local/man/man3' folder and uses it as a target paths."`
}

Buffered_File_Writer :: struct {
  fp: ^os.File,
  buf: [1024]byte,
  bw: bufio.Writer,
}

bfw_open_and_get_writer :: proc(bfw: ^Buffered_File_Writer, path: string) -> (w: io.Writer, err: os.Error) {
  bfw.fp = os.open(path, os.O_WRONLY|os.O_CREATE) or_return
  bufio.writer_init_with_buf(&bfw.bw, os.to_stream(bfw.fp), bfw.buf[:]) 
  return bufio.writer_to_writer(&bfw.bw), nil
}

bfw_close_and_destroy :: proc(bfw: ^Buffered_File_Writer) {
  os.close(bfw.fp)
  bufio.writer_destroy(&bfw.bw)
}


// outbase path

main :: proc() {
  // context variables
  perm_arena: virtual.Arena
  arena_err := virtual.arena_init_growing(&perm_arena)
  if arena_err != nil {
    fmt.println("error initiating permanent arena:", arena_err)
    return
  }
  defer virtual.arena_destroy(&perm_arena)
  perm_alloc := virtual.arena_allocator(&perm_arena)

  // global variables
  w: io.Writer
  ferr: os.Error

  // command line argumenet processing arguments
  source_path: string
  prefix: string
  subpath: string
  base_name: string
  prefix_outpath: string

  { // parsing option arguments
    temp_alloc := context.temp_allocator
    defer free_all(temp_alloc)
    opt: Options
    flags.parse_or_exit(&opt, os.args, .Odin, temp_alloc)

    if opt.path == "" {
      source_path, ferr = os.get_working_directory(perm_alloc)
      if ferr != nil {
        fmt.println("Cannot get current working directory path, please provide a target directory or file")
        return
      }
    } else {
      if sep := strings.index_rune(opt.path, ':'); sep >= 0 {
        state, stdout, _, err := os.process_exec({ command = {"odin", "root"} }, temp_alloc)
        if !state.success || err != nil {
          fmt.println("Cannot get directory by calling `odin root`. Please write a complete path")
          fmt.println("Error:", err)
          return
        }
        odin_path := strings.clone(string(stdout), perm_alloc)
        prefix = strings.clone(opt.path[:sep], perm_alloc)
        subpath = strings.clone(opt.path[sep+1:], perm_alloc)

        source_path = slashpath.join({odin_path, prefix, subpath}, perm_alloc)
      } else {
        source_path = strings.clone(opt.path, perm_alloc)
      }
    }

    if opt.install {
      man_path :: "/usr/local/share/man/man3/"
      if os.is_dir(man_path) {
        prefix_outpath = man_path
      } else {
        fmt.println("error: `", man_path, "` does not exist")
        return
      }
    }
    base_name = os.base(source_path)
  }

  // Environement Variables
  date: string
  collection: string
  title: string
  version: string

  {
    // making date
    temp_alloc := context.temp_allocator
    defer free_all(temp_alloc)

    year, month, _ := time.date(time.now())
    date = strings.concatenate({
        reflect.enum_string(month),
        fmt.aprint(year, allocator = temp_alloc),
      },
      perm_alloc,
    )

    // making collection name
    if prefix == "" {
      collection = "Odin Code Documentation"
    } else {
      to_upper_char(raw_data(prefix))
      collection = strings.concatenate({"Odin Collection ", prefix}, perm_alloc);
    }

    // getting odin version
    state, version_bytes, _, err := os.process_exec({ command = {"odin", "version"} }, temp_alloc)
    if !state.success || err != nil {
      fmt.println("Cannot get version by calling `odin version`")
      fmt.println("Error:", err)
      version = "unknown_version"
    } else {
      version = string(version_bytes)
      version = strings.trim_space(version)
      last_space := strings.last_index_byte(version, ' ')
      version = strings.clone(version[last_space:], perm_alloc)
    }
  }

  // opennig root_file and parsing files
  root_file, open_err := os.open(source_path)
  if open_err != nil {
    fmt.println("failed to open path:", source_path)
    return
  }
  defer os.close(root_file)
  root_info, stat_err := os.fstat(root_file, perm_alloc)
  if stat_err != nil {
    fmt.println("failed to get path info:", source_path)
    return
  }

  #partial switch root_info.type {
  case .Directory:
    file_informations, ferr := os.read_directory(root_file, 0, perm_alloc)
    if ferr != nil {
      fmt.println("failed to read directory:", source_path, "error:", ferr)
      return
    }

    package_root_index := -1
    for i := 0; i < len(file_informations); i += 1 {
      type := file_informations[i].type
      stemmed := os.stem(file_informations[i].name)
      extension := os.ext(file_informations[i].name)

      if type == .Regular && stemmed == base_name && extension == ".odin" {
        package_root_index = i
      }
    }

    outpath := strings.concatenate({prefix_outpath, "odin_", base_name, ".3"}, perm_alloc)
    // opening output file
    outfile: Buffered_File_Writer
    w, ferr = bfw_open_and_get_writer(&outfile, outpath)
    if ferr != nil {
      fmt.println("failed to open output file:", outpath, "error:", ferr)
      return
    }
    defer bfw_close_and_destroy(&outfile)
    defer io.flush(w)

    title = strings.concatenate({"ODIN_", os.stem(base_name)}, perm_alloc);
    to_upper(transmute([]u8)(title))
    werr := man.write_header(w, title, date, collection, version)
    if werr != nil {
      fmt.println("failed to write header in", outpath, "error:", werr)
      return
    }

    if package_root_index != -1 {
      path := file_informations[package_root_index].fullpath
      man.read_parse_and_write_description_and_declarations(w, path);
    }

    for i := 0; i < len(file_informations); i += 1 {
      if file_informations[i].type == .Regular &&
        os.ext(file_informations[i].name) == "odin" &&
        i != package_root_index {
        path := file_informations[i].fullpath
        man.read_parse_and_write_declarations_from_path(w, path)
      }
    }

  case .Regular:
    job_alloc := context.temp_allocator
    defer free_all(job_alloc)
    file_content: []byte

    title = strings.concatenate({"ODIN_", os.stem(base_name), "_FILE"}, job_alloc);
    to_upper(transmute([]u8)(title))
    // @note: title = nil, date - ok, collection - ok, version - not ok
    outpath := strings.concatenate({prefix_outpath, "odin_", base_name, "_file.3"}, perm_alloc)
    // opening output file
    outfile: Buffered_File_Writer
    w, ferr = bfw_open_and_get_writer(&outfile, outpath)
    if ferr != nil {
      fmt.println("failed to open output file:", outpath, "error:", ferr)
      return
    }
    defer bfw_close_and_destroy(&outfile)
    defer io.flush(w)
    werr := man.write_header(w, title, date, collection, version)
    if werr != nil {
      fmt.println("failed to write header:", werr)
      return
    }

    man.read_parse_and_write_description_and_declarations(w, root_file);
  case:
    fmt.println("unsupported file type")
  }
}
