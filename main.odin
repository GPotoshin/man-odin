package main

import "base:runtime"
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

Options :: struct {
  path: string `args:"pos=0" usage:"Target directory or file. Current working directory is default. Can be prefixed with collection"`,
  out: string `usage:"Sets output path. The default one is '/usr/local/share/man'. Files are saved under 'man3' directory"`,
  all_collections: bool `usage:"Generates manuals for every package of every collection"`,
}

Buffered_File_Writer :: struct {
  fp: ^os.File,
  buf: [4096]byte, // gp: 4k is about optimal
  bw: bufio.Writer,
}

bfw_open_and_get_writer :: proc(bfw: ^Buffered_File_Writer, path: string) -> (w: io.Writer, err: os.Error) {
  bfw.fp = os.open(path, os.O_WRONLY|os.O_CREATE) or_return
  bufio.writer_init_with_buf(&bfw.bw, os.to_stream(bfw.fp), bfw.buf[:]) 
  return bufio.writer_to_writer(&bfw.bw), nil
}

bfw_close_and_destroy :: proc(bfw: ^Buffered_File_Writer) {
  _ = bufio.writer_flush(&bfw.bw)
  os.close(bfw.fp)
  bufio.writer_destroy(&bfw.bw)
}

Gen_Info :: struct {
	prefix: string, // e.g. core, base, vendor or ""
  out_path: string,
  root_path: string,
  header_data: man.Header_Data,
  file_infos: []os.File_Info, // optional
}

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
  temp_alloc := context.temp_allocator

  // global variables
  w: io.Writer
  ferr: os.Error
  opt: Options
  gen_info: Gen_Info 

  // command line argument processing arguments
  subpath: string
  odin_path: string
  gen_info.out_path = "/usr/local/share/man/man3"

  { // parsing option arguments
    defer free_all(temp_alloc)
    flags.parse_or_exit(&opt, os.args, .Odin, temp_alloc)

    if opt.all_collections || opt.path != "" {
      state, stdout, _, err := os.process_exec({ command = {"odin", "root"} }, temp_alloc)
      if !state.success || err != nil {
        log.errorf("Cannot get directory by calling `odin root`. Please use a complete path. Error: %v\n", err)
        return
      }
      odin_path = strings.clone(string(stdout), perm_alloc)
    }

    if opt.path == "" && !opt.all_collections {
      gen_info.root_path, ferr = os.get_working_directory(perm_alloc)
      if ferr != nil {
        fmt.println("Cannot get current working directory path, please provide a target directory or file")
        return
      }
    } else if !opt.all_collections {
      if sep := strings.index_rune(opt.path, ':'); sep >= 0 {
        gen_info.prefix = strings.clone(opt.path[:sep], perm_alloc)
        subpath = strings.clone(opt.path[sep+1:], perm_alloc)
        gen_info.root_path = slashpath.join({odin_path, gen_info.prefix, subpath}, perm_alloc)
      } else {
        gen_info.root_path = strings.clone(opt.path, perm_alloc)
      }
    }

    if opt.out != "" && os.is_dir(opt.out) {
      if !os.is_dir(opt.out) {
        fmt.println("error: `", opt.out, "` does not exist")
        return
      }
      gen_info.out_path = slashpath.join({opt.out, "man3"}, perm_alloc)
    }
    if !os.is_dir(gen_info.out_path) {
      if mk_err := os.make_directory_all(gen_info.out_path); mk_err != nil {
        fmt.println("error: cannot create `", gen_info.out_path, "`,", mk_err)
        return
      }
    }
  }

  {
    // making date
    defer free_all(temp_alloc)

    year, month, _ := time.date(time.now())
    gen_info.header_data.date = strings.concatenate({
        reflect.enum_string(month),
        fmt.aprint(year, allocator = temp_alloc),
      },
      perm_alloc,
    )

    // making collection name
    if gen_info.prefix == "" {
      gen_info.header_data.collection = "Odin Code Documentation"
    } else {
      gen_info.header_data.collection = man.odin_collection_string(gen_info.prefix);
    }

    // getting odin version
    state, version_bytes, _, err := os.process_exec({ command = {"odin", "version"} }, temp_alloc)
    if !state.success || err != nil {
      fmt.println("Cannot get version by calling `odin version`")
      fmt.println("Error:", err)
      gen_info.header_data.version = "unknown_version"
    } else {
      gen_info.header_data.version = string(version_bytes)
      gen_info.header_data.version = strings.trim_space(gen_info.header_data.version)
      last_space := strings.last_index_byte(gen_info.header_data.version, ' ')
      gen_info.header_data.version = strings.clone(gen_info.header_data.version[last_space:], perm_alloc)
    }
  }

  if opt.all_collections {
    collections :: []string{"base", "core", "vendor"}
    for collection in collections {
      gen_info.root_path = slashpath.join({odin_path, collection}, temp_alloc)
      gen_info.header_data.collection = man.odin_collection_string(collection)
      do_all_packages_rec(gen_info)
    }
    return
  }

  // opening root_file and parsing files
  root_info: os.File_Info
  root_file, open_err := os.open(gen_info.root_path)
  if open_err != nil {
    fmt.println("failed to open path:", gen_info.root_path)
    return
  }
  defer os.close(root_file)
  stat_err: os.Error
  root_info, stat_err = os.fstat(root_file, perm_alloc)
  if stat_err != nil {
    log.errorf("failed to get path `%s` info: %v\n", gen_info.root_path, stat_err)
    return
  }

  #partial switch root_info.type {
  case .Directory:
    do_package(root_file, gen_info)

  case .Regular:
    job_alloc := context.temp_allocator
    defer free_all(job_alloc)
    file_content: []byte
    base_name := os.base(gen_info.root_path)

    title := strings.concatenate({"ODIN_", os.stem(base_name), "_FILE"}, job_alloc);
    man.to_upper(transmute([]u8)(title))
    out_file_name := strings.concatenate({"odin_", base_name, "_file.3"}, perm_alloc)
    outpath := slashpath.join({gen_info.out_path, out_file_name}, perm_alloc)
    // opening output file
    outfile: Buffered_File_Writer
    w, ferr = bfw_open_and_get_writer(&outfile, outpath)
    if ferr != nil {
      fmt.println("failed to open output file:", outpath, "error:", ferr)
      return
    }
    defer bfw_close_and_destroy(&outfile)
    werr := man.write_header(w, gen_info.header_data)
    if werr != nil {
      fmt.println("failed to write header:", werr)
      return
    }

    man.read_parse_and_write_description_and_declarations(w, root_file, gen_info.prefix);
  case:
    fmt.println("unsupported file type")
  }
}

do_package :: proc(root_file: ^os.File, gen_info: Gen_Info) {
  gen_info := gen_info
  scratch := runtime.default_temp_allocator_temp_begin()
  defer runtime.default_temp_allocator_temp_end(scratch)
  base_name := os.base(gen_info.root_path)
 
  ferr: os.Error
  file_infos: []os.File_Info
  if gen_info.file_infos != nil {
    file_infos = gen_info.file_infos 
  } else {
    file_infos, ferr = os.read_directory(root_file, 0, context.temp_allocator)
    if ferr != nil {
      fmt.println("failed to read directory:", gen_info.root_path, "error:", ferr)
      return
    }
  }

  package_root_index := -1
  for i := 0; i < len(file_infos); i += 1 {
    type := file_infos[i].type
    stemmed := os.stem(file_infos[i].name)
    extension := os.ext(file_infos[i].name)

    if type == .Regular && stemmed == base_name && extension == ".odin" {
      package_root_index = i
    }
  }

  outpath := strings.concatenate({gen_info.out_path, "/odin_", base_name, ".3"}, context.temp_allocator)
  // opening output file
  w: io.Writer
  outfile: Buffered_File_Writer
  w, ferr = bfw_open_and_get_writer(&outfile, outpath)
  if ferr != nil {
    fmt.println("failed to open output file:", outpath, "error:", ferr)
    return
  }
  defer bfw_close_and_destroy(&outfile)

  gen_info.header_data.title = strings.concatenate({"ODIN_", os.stem(base_name)}, context.temp_allocator);
  man.to_upper(transmute([]u8)(gen_info.header_data.title))
  werr := man.write_header(w, gen_info.header_data)
  if werr != nil {
    fmt.println("failed to write header in", outpath, "error:", werr)
    return
  }

  if package_root_index != -1 {
    path := file_infos[package_root_index].fullpath
    man.read_parse_and_write_description_and_declarations(w, path, gen_info.prefix); // it should not be the base_name
  }

  for i := 0; i < len(file_infos); i += 1 {
    if file_infos[i].type == .Regular &&
    os.ext(file_infos[i].name) == ".odin" &&
    i != package_root_index {
      path := file_infos[i].fullpath
      man.read_parse_and_write_declarations_from_path(w, path)
    }
  }
}

do_all_packages_rec :: proc(gen_info: Gen_Info) {
  gen_info := gen_info
  scratch := runtime.default_temp_allocator_temp_begin()
  defer runtime.default_temp_allocator_temp_end(scratch)
  
  root_path := gen_info.root_path

  file_infos: []os.File_Info
  {
    any_files := false
    root_file, ferr := os.open(root_path)
    defer os.close(root_file)
    if ferr != nil {
      log.errorf("Failed opening path: %s\n", root_path)
      return
    }

    file_infos, ferr = os.read_directory(root_file, 0, context.temp_allocator)
    if ferr != nil {
      fmt.println("failed to read directory:", root_path, "error:", ferr)
      return
    }

    for file in file_infos {
      if file.type == .Regular && os.ext(file.name) == ".odin" {
        any_files = true
        break
      }
    }

    gen_info.file_infos = file_infos
    if any_files do do_package(root_file, gen_info)
    gen_info.file_infos = nil
  }

  for file in file_infos {
    if file.type == .Directory {
      gen_info.root_path = file.fullpath
      do_all_packages_rec(gen_info)
    }
  }
}
