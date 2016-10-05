(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core

(*****************************************************************************)
(* Table containing all the Abstract Syntax Trees (cf ast.ml) for each file.*)
(*****************************************************************************)

(* We store only the names and declarations in the ParserHeap.
   The full flag in each function runs a full parsing with method bodies. *)

type parse_type = Decl of string | Full

module ParserHeap = SharedMem.WithCache (Relative_path.S) (struct
    type t = Ast.program * parse_type
    let prefix = Prefix.make()
    let description = "Parser"
  end)

module LocalParserHeap = SharedMem.LocalCache (Relative_path.S) (struct
    type t = Ast.program
    let prefix = Prefix.make()
    let description = "ParserLocal"
  end)

let get_from_local_heap popt file_name contents =
  match LocalParserHeap.get file_name with
  | Some ast ->ast
  | None ->
        let { Parser_hack.ast;
          _ } = Parser_hack.program popt file_name contents in
        LocalParserHeap.add file_name ast;
        ast

let get_class defs class_name =
  List.fold_left defs ~init:None ~f:begin fun acc def ->
    match def with
    | Ast.Class c when snd c.Ast.c_name = class_name -> Some c
    | _ -> acc
  end

let get_fun defs fun_name =
  List.fold_left defs ~init:None ~f:begin fun acc def ->
    match def with
    | Ast.Fun f when snd f.Ast.f_name = fun_name -> Some f
    | _ -> acc
  end

let get_typedef defs name =
  List.fold_left defs ~init:None ~f:begin fun acc def ->
    match def with
    | Ast.Typedef typedef when snd typedef.Ast.t_id = name -> Some typedef
    | _ -> acc
  end

let get_const defs name =
  List.fold_left defs ~init:None ~f:begin fun acc def ->
    match def with
    | Ast.Constant cst when snd cst.Ast.cst_name = name -> Some cst
    | _ -> acc
  end

let get_from_parser_heap ?(full = false) ?popt file_name name get_element =
  match ParserHeap.get file_name with
    | None -> None
    | Some (_, Decl content) when full ->
      let ast = get_from_local_heap (Utils.unsafe_opt popt) file_name content in
      get_element ast name
    | Some (defs, _) -> get_element defs name

let find_class_in_file file_name class_name =
  get_from_parser_heap file_name class_name get_class

let find_class_in_file_full popt file_name class_name =
  get_from_parser_heap ~full:true ~popt file_name class_name get_class

let find_fun_in_file file_name fun_name =
  get_from_parser_heap file_name fun_name get_fun

let find_fun_in_file_full popt file_name fun_name =
  get_from_parser_heap ~full:true ~popt file_name fun_name get_fun

let find_typedef_in_file file_name name =
  get_from_parser_heap file_name name get_typedef

let find_typedef_in_file_full popt file_name name =
  get_from_parser_heap ~full:true ~popt file_name name get_typedef

let find_const_in_file file_name name =
  get_from_parser_heap file_name name get_const

let find_const_in_file_full popt file_name name =
  get_from_parser_heap ~full:true ~popt file_name name get_const
