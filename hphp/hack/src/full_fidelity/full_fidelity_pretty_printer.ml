(**
* Copyright (c) 2016, Facebook, Inc.
* All rights reserved.
*
* This source code is licensed under the BSD-style license found in the
* LICENSE file in the "hack" directory of this source tree. An additional grant
* of patent rights can be found in the PATENTS file in the same directory.
*
*)

(* The general approach of the pretty printer is to give as much flexibility in
 * terms of where a newline can occur as possible, while maintaining a sensible
 * layout that is considerred human readable and "normal"
 * An optional break is introduced whenever it is possible for a line break to
 * occur in real life. Small components are grouped together so that each
 * component decide their layouts individually.
 * Single line comments is the exception to everything: a newline is forced at
 * the end of a single line comments even if the line otherwise fits. This rule
 * overrides the default behaviour of some operators, such as immediate_cons ^^^
 * which otherwise does not even introduce a break.
 * Design decisions include:
 *  1. Each statement is separated from others using a line break
 *  2. Brackets/parenthesis/braces are either both on different lines with child
 *     or both on the same line with the entire child on one line as well
 *  3. binary operators can be on different lines with arguments
 *  4. unary operators must be on the same line as the argument
 *  5. semicolons have to be on the same line as the last line of the statement
 *     that it ends
 *  6. Switch statements are specially treated since case label is only a label
 *     and not a block in the grammar. Cases are broken up into blocks in the
 *     printer and each case is grouped together to have individual layout
 *     options
 *)

(* The main data type that is used in the pretty printer is a 5 tuple:
 *
 *   (l_trivia, l_single, doc, r_trivia, r_single)
 *
 *   l_trivia: the doc generated from the leading trivia of the syntax node
 *   l_single: whether the leading trivia contains a single line comment
 *   doc     : the doc generated from the main body of the syntax node
 *   r_trivia: the doc generated from trailing trivia of the syntax node
 *   r_single: whether the trailing trivia contains a single line comment
 *)
open Pretty_printing_library_sig
open Limited_width_pretty_printing_library
(* utility functions to make combinators look simpler
 * See Lindig's paper for reference *)
module Utility (P : Library) = struct
  include P

  let space = text " "

  let absorb_nil_cons doc1 doc2 delimiter =
    match doc1, doc2 with
    | Nil, _ -> doc2
    | _, Nil -> doc1
    | _, _ -> doc1 ^^ delimiter ^^ doc2

  let break_cons doc1 doc2 = absorb_nil_cons doc1 doc2 break

  let space_cons doc1 doc2 = absorb_nil_cons doc1 doc2 space

  let choose_cons must is_empty x y =
    let delimiter =
      if must then must_break
      else if is_empty then breakwith ""
      else break
    in
    absorb_nil_cons x y delimiter


  let group_doc (x_lead, x_lead_single, x, x_trail, x_trail_single) =
    let optional_group = if x = Nil then x else group x in
    (x_lead, x_lead_single, optional_group, x_trail, x_trail_single)

  let combine (l_lead, l_lead_single, l, l_trail, l_trail_single) =
    let front_part = choose_cons l_lead_single false l_lead (group l) in
    space_cons front_part l_trail

  (* higher order function to combine two docs with leading and trailing
   * comments. This function creates a front part and a back part in a fixed
   * way and takes a function that combines the two parts in different ways *)
  let doc_combinor x y combinor =
    let (l_lead, l_lead_single, l, l_trail, l_trail_single) = x in
    let (r_lead, r_lead_single, r, r_trail, r_trail_single) = y in
    let front_p = space_cons l l_trail in
    let end_p = choose_cons r_lead_single false r_lead r in
    match l, r with
    | Nil, _ -> (r_lead, r_lead_single, r, r_trail, r_trail_single)
    | _, Nil -> (l_lead, l_lead_single, l, l_trail, l_trail_single)
    | _, _ ->
      (l_lead, l_lead_single, combinor front_p end_p, r_trail, r_trail_single)

  let doc_cons_opt empty x y =
    let (_, _, _, _, l_trail_single) = x in
    let combinor front_part end_part =
      choose_cons l_trail_single empty front_part end_part in
    doc_combinor x y combinor

  let doc_cons = doc_cons_opt false
  let (^|) = doc_cons

  let doc_cons_empty = doc_cons_opt true
  let (^^|) = doc_cons_empty

  let immediate_cons x y =
    let (_, _, _, _, l_trail_single) = x in
    let (_, r_lead_single, _, _, _) = y in
    let combinor front_part end_part =
      if l_trail_single || r_lead_single then
        choose_cons true false front_part end_part
      else front_part ^^ end_part
    in
    doc_combinor x y combinor
  let (^^^) = immediate_cons

  (* indent [r] by [indent] after [l] using the suitable line break *)
  let choose_indent_doc empty x y indent =
    let (_, _, _, _, l_trail_single) = x in
    let combinor front_part end_part =
      let break_choice =
       if l_trail_single then must_break
       else if empty then breakwith ""
       else break
      in
      front_part ^^ nest indent (break_choice ^^ end_part)
    in
    doc_combinor x y combinor

  (* put a break before [r] and nest [r] by [indent] in vertical layout *)
  let indent_doc = choose_indent_doc false

  let indent_doc_no_space = choose_indent_doc true

  (* typically we will want to indent block [blk] that is enclosed by
  * [l] and [r] by amount [indt] *)
  let indent_block l blk r indt =
    group_doc (indent_doc l blk indt ^| r)

  let indent_block_no_space l blk r indt =
    group_doc ((indent_doc_no_space l blk indt) ^^| r)

  let add_break (a, b, c, d, e) = (a, b, c, d, true)
end

module LineConf = struct
 let line_width = 80
end
module Comparator = WidthConstrainedDocComparator(LineConf)
module Core = Pretty_printing_library.Make(Comparator)
module Printer = Utility(Core)
module Syntax = Full_fidelity_editable_syntax
module EditableToken = Full_fidelity_editable_token
open Syntax
open Printer

let get_doc_from_trivia trivia_lst allow_break =
  (* generate a document from a list of trivias. Return the doc, as well
   * as whether the trivia list contains a single line comment *)
  let module Trivia = Full_fidelity_editable_trivia in
  let module Kind = Full_fidelity_trivia_kind in
  let handle_trivia trivia = match Trivia.kind trivia with
    | Kind.WhiteSpace -> (nil, false)
    | Kind.EndOfLine -> (nil, false)
    | Kind.SingleLineComment ->
      (* no code after comments *)
      (text (Trivia.text trivia), true)
    | Kind.DelimitedComment ->
      (text (Trivia.text trivia), false)
  in
  let concat = if allow_break then break_cons else space_cons in
  let fold_fun x y =
    let (a, c1) = x in
    let (b, c2) = y in
    let result = concat a b in
    (result, c1 || c2)
  in
  (* no group here, since all breaks are compulsory. Will group on top level *)
  List.fold_left fold_fun (nil, false) (List.map handle_trivia trivia_lst)

let from_token x =
  let front_trivias = EditableToken.leading x in
  let end_trivias = EditableToken.trailing x in
  let (front_doc, front_single) = get_doc_from_trivia front_trivias true in
  let (end_doc, end_single) = get_doc_from_trivia end_trivias false in
  let doc = text (EditableToken.text x) in
  (front_doc, front_single, doc, end_doc, end_single)

(* create a 5-tuple (see top of file) from x with no trivias *)
let make_simple x = (nil, false, x, nil, false)
let indt = 2
let missing = make_simple nil
let error_header = make_simple (text "Error:")
let space = make_simple (text " ")
let colon = make_simple (text ":")
let comma = make_simple (text ",")
let l_square = make_simple (text "[")
let r_square = make_simple (text "]")

let rec get_doc node =
  match syntax node with
  | Missing -> missing
  | Token x -> from_token x

  | SyntaxList x -> get_from_children x
  | Error { error } -> get_doc error
  | LiteralExpression x -> get_doc x.literal_expression
  | VariableExpression x -> get_doc x.variable_expression
  | QualifiedNameExpression x -> get_doc x.qualified_name_expression
  | PipeVariableExpression x -> get_doc x.pipe_variable_expression
  | ListItem x -> (get_doc x.list_item) ^^^ (get_doc x.list_separator)
  | ScriptHeader x -> get_doc x.header_less_than ^^^
                      get_doc x.header_question ^^^
                      (x.header_language |> get_doc |> add_break)
  | Script x -> group_doc ( get_doc x.script_header
                     ^| get_doc x.script_declarations )
  | ClassishDeclaration
    { classish_attribute; classish_modifiers; classish_keyword;
      classish_name; classish_type_parameter_list; classish_extends;
      classish_extends_list; classish_implements; classish_implements_list;
      classish_body } ->
    let attr = add_break (get_doc classish_attribute) in
    let preface = group_doc (
      get_doc classish_modifiers ^|
      get_doc classish_keyword
    ) in

    let name_and_generics =
      let name = get_doc classish_name in
      let type_params = get_doc classish_type_parameter_list in
      group_doc (indent_doc name type_params indt)
    in

    let extends =
      let extends_token = get_doc classish_extends in
      let extends_list = get_doc classish_extends_list in
      group_doc (indent_doc extends_token extends_list indt)
    in

    let implements =
      let implements_token = get_doc classish_implements in
      let implements_list = get_doc classish_implements_list in
      group_doc (indent_doc implements_token implements_list indt)
    in

    let body = get_doc classish_body in

    (* TODO: Make this better *)
    attr ^^^
    group_doc (
      group_doc (
        preface ^|
        name_and_generics
      ) ^|
      group_doc (
        extends ^|
        implements
      ) ^|
      body
    )
  | ClassishBody x ->
    let left = get_doc x.classish_body_left_brace in
    let right = get_doc x.classish_body_right_brace in
    let body = get_doc x.classish_body_elements in
    indent_block_no_space left body right indt
  | XHPRequired x ->
    let a = get_doc x.xhp_required_at in
    let r = get_doc x.xhp_required in
    a ^^^ r
  | XHPChildrenDeclaration x ->
    let c = get_doc x.xhp_children in
    let e = get_doc x.xhp_children_expression in
    let s = get_doc x.xhp_children_semicolon in
    c ^| e ^^^ s
  | XHPCategoryDeclaration x ->
    let c = get_doc x.xhp_category in
    let l = get_doc x.xhp_category_list in
    let s = get_doc x.xhp_category_semicolon in
    c ^| l ^^^ s
  | XHPEnumType x ->
    let e = get_doc x.xhp_enum_keyword in
    let l = get_doc x.xhp_enum_left_brace in
    let v = get_doc x.xhp_enum_values in
    let r = get_doc x.xhp_enum_right_brace in
    group_doc (e ^| l ^| v ^| r)
  | XHPClassAttributeDeclaration
    { xhp_attribute_keyword; xhp_attribute_list; xhp_attribute_semicolon } ->
    let attr = get_doc xhp_attribute_keyword in
    let attrs = get_doc xhp_attribute_list in
    let semi = get_doc xhp_attribute_semicolon in
    group_doc (attr ^| attrs ^^^ semi)
  | XHPClassAttribute
    { xhp_attribute_decl_type; xhp_attribute_decl_name;
      xhp_attribute_decl_initializer; xhp_attribute_decl_required } ->
    let t = get_doc xhp_attribute_decl_type in
    let n = get_doc xhp_attribute_decl_name in
    let i = get_doc xhp_attribute_decl_initializer in
    let r = get_doc xhp_attribute_decl_required in
    group_doc (t ^| n ^| i ^| r)
  | TraitUse x ->
    let use = get_doc x.trait_use_keyword in
    let name_list = get_doc x.trait_use_name_list in
    let semi = get_doc x.trait_use_semicolon in
    use ^| name_list ^^^ semi
  | RequireClause x ->
    let r = get_doc x.require_keyword in
    let k = get_doc x.require_kind in
    let n = get_doc x.require_name in
    let s = get_doc x.require_semicolon in
    r ^| k ^| n ^^^ s
  | ConstDeclaration x ->
    let abstr = get_doc x.const_abstract in
    let token = get_doc x.const_keyword in
    let ty = get_doc x.const_type_specifier in
    let lst = get_doc x.const_declarator_list in
    let semi = get_doc x.const_semicolon in
    group_doc (abstr ^| token ^| ty ) ^| lst ^^^ semi
  | ConstantDeclarator x ->
    let name = get_doc x.constant_declarator_name in
    let init = get_doc x.constant_declarator_initializer in
    group_doc (name ^| init)
  | TypeConstDeclaration x ->
    let abstr = get_doc x.type_const_abstract in
    let const = get_doc x.type_const_keyword in
    let type_ = get_doc x.type_const_type_keyword in
    let name = get_doc x.type_const_name in
    let type_constraint = get_doc x.type_const_type_constraint in
    let equal = get_doc x.type_const_equal in
    let type_spec = get_doc x.type_const_type_specifier in
    let semicolon = get_doc x.type_const_semicolon in
    group_doc (
      group_doc (abstr ^| const ^| type_ ^| name) ^|
      type_constraint ^|
      equal ^|
      group_doc (type_spec ^^^ semicolon)
    )
  | EnumDeclaration x ->
    let en = get_doc x.enum_keyword in
    let na = get_doc x.enum_name in
    let co = get_doc x.enum_colon in
    let ba = get_doc x.enum_base in
    let ty = get_doc x.enum_type in
    let lb = get_doc x.enum_left_brace in
    let es = get_doc x.enum_enumerators in
    let rb = get_doc x.enum_right_brace in
    (* TODO: This could be a lot better. Add indentation, etc. *)
    en ^| na ^| co ^| ba ^| ty ^| lb ^| es ^| rb
  | Enumerator x ->
    let n = get_doc x.enumerator_name in
    let e = get_doc x.enumerator_equal in
    let v = get_doc x.enumerator_value in
    let semicolon = get_doc x.enumerator_semicolon in
    n ^| e ^| v ^^^ semicolon
  | AliasDeclaration x ->
    (* TODO: What's the best way to ensure that there's a newline between the
    attribute and the alias declaration proper? *)
    let attr = get_doc x.alias_attribute_spec in
    let a = get_doc x.alias_keyword in
    let n = get_doc x.alias_name in
    let generic = get_doc x.alias_generic_parameter in
    let c = get_doc x.alias_constraint in
    let e = get_doc x.alias_equal in
    let t = get_doc x.alias_type in
    let s = get_doc x.alias_semicolon in
    attr ^| a ^| n ^| generic ^| c ^| e ^| t ^^^ s
  | PropertyDeclaration
    { property_modifiers; property_type;
      property_declarators; property_semicolon } ->
    let m = get_doc property_modifiers in
    let t = get_doc property_type in
    let d = get_doc property_declarators in
    let s = get_doc property_semicolon in
    m ^| t ^| d ^^^ s
  | PropertyDeclarator { property_name; property_initializer } ->
    let n = get_doc property_name in
    let i = get_doc property_initializer in
    n ^| i
  | NamespaceDeclaration x ->
    let t = get_doc x.namespace_keyword in
    let n = get_doc x.namespace_name in
    let b = get_doc x.namespace_body in
    t ^| n ^| b
  | NamespaceBody x ->
    let left = get_doc x.namespace_left_brace in
    let body = get_doc x.namespace_declarations in
    let right = get_doc x.namespace_right_brace in
    indent_block_no_space left body right indt |> add_break
  | NamespaceUseDeclaration x ->
    let u = get_doc x.namespace_use_keyword in
    let k = get_doc x.namespace_use_kind in
    let c = get_doc x.namespace_use_clauses in
    let s = get_doc x.namespace_use_semicolon in
    u ^| k ^| c ^^^ s
  | NamespaceUseClause x ->
    let k = get_doc x.namespace_use_clause_kind in
    let n = get_doc x.namespace_use_name in
    let a = get_doc x.namespace_use_as in
    let l = get_doc x.namespace_use_alias in
    k ^| n ^| a ^| l
  | NamespaceGroupUseDeclaration x ->
    let u = get_doc x.namespace_group_use_keyword in
    let k = get_doc x.namespace_group_use_kind in
    let p = get_doc x.namespace_group_use_prefix in
    let l = get_doc x.namespace_group_use_left_brace in
    let c = get_doc x.namespace_group_use_clauses in
    let r = get_doc x.namespace_group_use_right_brace in
    let s = get_doc x.namespace_group_use_semicolon in
    u ^| k ^| p ^| l ^| c ^| r ^^^ s
  | FunctionDeclaration x ->
      let attr = get_doc x.function_attribute_spec in
      let header = get_doc x.function_declaration_header in
      let body = x.function_body in
      let after_attr = handle_compound_inline_brace header body missing in
      group_doc (attr ^| after_attr)
  | FunctionDeclarationHeader
    { function_async; function_keyword; function_name;
      function_type_parameter_list; function_left_paren;
      function_parameter_list; function_right_paren; function_colon;
      function_type }
   ->
    let preface = group_doc ( get_doc function_async
                              ^| get_doc function_keyword) in
    let name_and_generics =
      let type_params = get_doc function_type_parameter_list in
      let name = get_doc function_name in
      group_doc (indent_doc name type_params indt)
    in
    let parameters =
      let left = get_doc function_left_paren in
      let right = get_doc function_right_paren in
      let params = get_doc function_parameter_list in
      indent_block_no_space left params right indt
    in
    let type_declaration =
      let fun_colon = get_doc function_colon in
      let fun_type = get_doc function_type in
      group_doc (fun_colon ^| fun_type)
    in
    group_doc (
      group_doc ( group_doc (preface ^| name_and_generics) ^^| parameters )
      ^| type_declaration
    )
  | MethodishDeclaration
    { methodish_attribute; methodish_modifiers; methodish_function_decl_header;
      methodish_function_body; methodish_semicolon } ->
    let methodish_attr = get_doc methodish_attribute in
    let methodish_modifiers = get_doc methodish_modifiers in
    let function_header = get_doc methodish_function_decl_header in
    let body_node = methodish_function_body in
    let semicolon = get_doc methodish_semicolon in
    let before_body = group_doc (methodish_modifiers ^| function_header) in
    let after_attr =
      handle_compound_inline_brace before_body body_node missing in
    let after_attr = after_attr ^^^ semicolon in
    group_doc (methodish_attr ^| after_attr)
  | DecoratedExpression x ->
    let decorator = get_doc x.decorated_expression_decorator in
    let expression = get_doc x.decorated_expression_expression in
    group_doc (decorator ^^^ expression)
  | ParameterDeclaration
    { param_attribute; param_visibility; param_type; param_name;
      param_default } ->
    let attr = get_doc param_attribute in
    let visibility = get_doc param_visibility in
    let parameter_type = get_doc param_type in
    let parameter_name = get_doc param_name in
    let parameter_default = get_doc param_default in
    group_doc
      ( attr ^| visibility ^| parameter_type ^| parameter_name
      ^| parameter_default )
  | AttributeSpecification x ->
    let left = get_doc x.attribute_spec_left_double_angle in
    let right = get_doc x.attribute_spec_right_double_angle in
    let specs = get_doc x.attribute_spec_attribute_list in
    indent_block_no_space left specs right indt
  | Attribute x ->
    let name = get_doc x.attribute_name in
    let left = get_doc x.attribute_left_paren in
    let right = get_doc x.attribute_right_paren in
    let values = get_doc x.attribute_values in
    let left_part = group_doc (name ^^| left) in
    indent_block_no_space left_part values right indt
  | InclusionExpression x ->
    let rq = get_doc x.inclusion_require in
    let fn = get_doc x.inclusion_filename in
    rq ^| fn
  | InclusionDirective x ->
    let ex = get_doc x.inclusion_expression in
    let se = get_doc x.inclusion_semicolon in
    ex ^^^ se
  | CompoundStatement x ->
    let left = get_doc x.compound_left_brace in
    let right = get_doc x.compound_right_brace in
    let body = get_doc x.compound_statements in
    indent_block_no_space left body right indt |> add_break
  | ExpressionStatement x ->
    let body = get_doc x.expr_statement_expr in
    let semicolon = get_doc x.expr_statement_semicolon in
    (* semicolon always follows the last line *)
    body ^^^ semicolon |> group_doc |> add_break
  | WhileStatement
    { while_keyword; while_left_paren; while_condition; while_right_paren;
      while_body } ->
    let keyword = get_doc while_keyword in
    let left = get_doc while_left_paren in
    let condition = get_doc while_condition in
    let right = get_doc while_right_paren in
    let left_part = group_doc (keyword ^^| left) in
    let start_block = indent_block_no_space left_part condition right indt in
    handle_compound_brace_prefix_indent start_block while_body indt
    |> add_break
  | IfStatement
    { if_keyword; if_left_paren; if_condition; if_right_paren; if_statement;
      if_elseif_clauses; if_else_clause }->
    let keyword = get_doc if_keyword in
    let left = get_doc if_left_paren in
    let condition = get_doc if_condition in
    let right = get_doc if_right_paren in
    let if_stmt = if_statement in
    let elseif_clause = get_doc if_elseif_clauses in
    let else_clause = get_doc if_else_clause in
    let left_part = group_doc (keyword ^^| left) in
    let start_block = indent_block_no_space left_part condition right indt in
    let if_statement =
      handle_compound_brace_prefix_indent start_block if_stmt indt in
    let if_statement = add_break if_statement in
    group_doc (if_statement ^| elseif_clause ^| else_clause)
  | ElseifClause
    { elseif_keyword; elseif_left_paren; elseif_condition; elseif_right_paren;
      elseif_statement }  ->
    let keyword = get_doc elseif_keyword in
    let left = get_doc elseif_left_paren in
    let condition = get_doc elseif_condition in
    let right = get_doc elseif_right_paren in
    let elif_statement_syntax = elseif_statement in
    let left_part = group_doc (keyword ^^| left) in
    let start_block = indent_block_no_space left_part condition right indt in
    handle_compound_brace_prefix_indent start_block elif_statement_syntax indt
    |> add_break
  | ElseClause x ->
    let keyword = get_doc x.else_keyword in
    let statement = x.else_statement in
    handle_compound_brace_prefix_indent keyword statement indt
    |> add_break
  | TryStatement x ->
    let keyword = get_doc x.try_keyword in
    let compound_stmt = x.try_compound_statement in
    let try_part =
      handle_compound_brace_prefix_indent keyword compound_stmt indt in
    let catch_clauses = get_doc x.catch_clauses in
    let finally_clause = get_doc x.finally_clause in
    group_doc (try_part ^| catch_clauses ^| finally_clause)
    |> add_break
  | CatchClause x ->
    let keyword = get_doc x.catch_keyword in
    let left = get_doc x.catch_left_paren in
    let ty = get_doc x.catch_type in
    let var = get_doc x.catch_variable in
    let param = ty ^| var in
    let right = get_doc x.catch_right_paren in
    let stmt = x.catch_compound_statement in
    let front_part = group_doc (keyword ^| left) in
    let before_stmt = indent_block_no_space front_part param right indt in
    handle_compound_brace_prefix_indent before_stmt stmt indt
    |> add_break
  | FinallyClause x ->
    let keyword = get_doc x.finally_keyword in
    let stmt = x.finally_compound_statement in
    handle_compound_brace_prefix_indent keyword stmt indt
    |> add_break
  | DoStatement x ->
    let keyword = get_doc x.do_keyword in
    let statement = x.do_statement in
    let while_keyword = get_doc x.do_while_keyword in
    let left = get_doc x.do_left_paren in
    let right = get_doc x.do_right_paren in
    let condition = get_doc x.do_condition_expr in
    let semicolon = get_doc x.do_semicolon in
    let statement_part =
      handle_compound_brace_prefix_indent keyword statement indt |> add_break in
    let left_part = group_doc (while_keyword ^^| left) in
    let condition_part = indent_block_no_space left_part condition right indt in
    group_doc (statement_part ^| condition_part) ^^^ semicolon
  | ForStatement x ->
    let keyword = get_doc x.for_keyword in
    let left_paren = get_doc x.for_left_paren in
    let initializer_expr = get_doc x.for_initializer_expr in
    let first_semicolon = get_doc x.for_first_semicolon in
    let control_expr = get_doc x.for_control_expr in
    let second_semicolon = get_doc x.for_second_semicolon in
    let end_of_loop_expr = get_doc x.for_end_of_loop_expr in
    let right_paren = get_doc x.for_right_paren in
    let statement = x.for_statement in

    let left_part = group_doc (keyword ^^| left_paren) in

    let for_expressions =
      control_expr ^^^ second_semicolon ^| end_of_loop_expr in
    let for_expressions = if is_missing x.for_control_expr
      then first_semicolon ^^| for_expressions
      else first_semicolon ^| for_expressions
    in
    let for_expressions = group_doc (initializer_expr ^^^ for_expressions) in

    let start_block =
      indent_block_no_space left_part for_expressions right_paren indt
    in
    handle_compound_brace_prefix_indent start_block statement indt |> add_break
  | ForeachStatement x ->
    let keyword = get_doc x.foreach_keyword in
    let left = get_doc x.foreach_left_paren in
    let right = get_doc x.foreach_right_paren in
    let collection_name = get_doc x.foreach_collection_name in
    let await_keyword = get_doc x.foreach_await_opt in
    let as_keyword = get_doc x.foreach_as in
    let key = get_doc x.foreach_key_opt in
    let arrow = get_doc x.foreach_key_arrow_opt in
    let value = get_doc x.foreach_value in
    let statement = x.foreach_statement in
    let left_part = group_doc (keyword ^| left) in
    let arrow_part = group_doc (group_doc (key ^| arrow) ^| value) in
    let as_part = group_doc (await_keyword ^| as_keyword) in
    let as_part = group_doc (collection_name ^| as_part) in
    let middle_part = group_doc (as_part ^| arrow_part) in
    let start_block = indent_block_no_space left_part middle_part right indt in
    handle_compound_brace_prefix_indent start_block statement indt |> add_break
  | SwitchStatement x ->
    let keyword = get_doc x.switch_keyword in
    let left = get_doc x.switch_left_paren in
    let right = get_doc x.switch_right_paren in
    let expr = get_doc x.switch_expr in
    let left_part = group_doc (keyword ^^| left) in
    let start_block = indent_block_no_space left_part expr right indt in
    handle_switch start_block x
    (* group_doc (start_block ^| statement) *)
  | ScopeResolutionExpression x ->
    let q = get_doc x.scope_resolution_qualifier in
    let o = get_doc x.scope_resolution_operator in
    let n = get_doc x.scope_resolution_name in
    group_doc (q ^^^ o ^^^ n)
  | MemberSelectionExpression
    { member_object; member_operator; member_name } ->
    let ob = get_doc member_object in
    let op = get_doc member_operator in
    let nm = get_doc member_name in
    group_doc (ob ^^^ op ^^^ nm)
  | SafeMemberSelectionExpression
    { safe_member_object; safe_member_operator; safe_member_name } ->
    let ob = get_doc safe_member_object in
    let op = get_doc safe_member_operator in
    let nm = get_doc safe_member_name in
    group_doc (ob ^^^ op ^^^ nm)
  | YieldExpression x ->
    let y = get_doc x.yield_keyword in
    let o = get_doc x.yield_operand in
    group_doc (y ^| o)
  | PrintExpression x ->
    let t = get_doc x.print_keyword in
    let e = get_doc x.print_expr in
    group_doc (t ^| e)
  | CastExpression x ->
    let l = get_doc x.cast_left_paren in
    let t = get_doc x.cast_type in
    let r = get_doc x.cast_right_paren in
    let o = get_doc x.cast_operand in
    group_doc (l ^^^ t ^^^ r ^^^ o)
  | LambdaExpression x ->
    let async = get_doc x.lambda_async in
    let signature = get_doc x.lambda_signature in
    let arrow = get_doc x.lambda_arrow in
    let body = get_doc x.lambda_body in
    group_doc (async ^| signature ^| arrow ^| body)
  | LambdaSignature
    { lambda_left_paren; lambda_parameter_list; lambda_right_paren;
      lambda_colon; lambda_type } ->
    let left = get_doc lambda_left_paren in
    let params = get_doc lambda_parameter_list in
    let right = get_doc lambda_right_paren in
    let colon = get_doc lambda_colon in
    let ty = get_doc lambda_type in
    group_doc (left ^| params ^| right ^| colon ^| ty)
  | AnonymousFunction
    { anonymous_async; anonymous_function; anonymous_left_paren;
    anonymous_parameter_list; anonymous_right_paren; anonymous_colon;
    anonymous_type; anonymous_use; anonymous_body } ->
    let async = get_doc anonymous_async in
    let fn = get_doc anonymous_function in
    let left = get_doc anonymous_left_paren in
    let params = get_doc anonymous_parameter_list in
    let right = get_doc anonymous_right_paren in
    let colon = get_doc anonymous_colon in
    let return_type = get_doc anonymous_type in
    let preface = group_doc ( async ^| fn ) in
    let parameters = indent_block_no_space left params right indt in
    let type_declaration = group_doc (colon ^| return_type) in
    let uses = get_doc anonymous_use in
    let body = anonymous_body in
    let before_body =
      group_doc (
        group_doc ( group_doc preface ^^| parameters )
        ^| type_declaration ^| uses
      ) in
      handle_compound_inline_brace before_body body missing
  | AnonymousFunctionUseClause x ->
    let u = get_doc x.anonymous_use_keyword in
    let l = get_doc x.anonymous_use_left_paren in
    let v = get_doc x.anonymous_use_variables in
    let r = get_doc x.anonymous_use_right_paren in
    u ^| l ^^^ v ^^^ r
  | PrefixUnaryOperator
    { prefix_unary_operator; prefix_unary_operand } ->
    if is_separable_prefix prefix_unary_operator then
      get_doc prefix_unary_operator ^| get_doc prefix_unary_operand
    else
      get_doc prefix_unary_operator ^^^ get_doc prefix_unary_operand
  | PostfixUnaryOperator
    { postfix_unary_operand; postfix_unary_operator } ->
    get_doc postfix_unary_operand ^^^ get_doc postfix_unary_operator
  | BinaryOperator x ->
    let left = get_doc x.binary_left_operand in
    let op = get_doc x.binary_operator in
    let right = get_doc x.binary_right_operand in
    group_doc (left ^| op ^| right)
  | InstanceofExpression x ->
    let left = get_doc x.instanceof_left_operand in
    let op = get_doc x.instanceof_operator in
    let right = get_doc x.instanceof_right_operand in
    group_doc (left ^| op ^| right)
  | ConditionalExpression x ->
    let tst = get_doc x.conditional_test in
    let qm = get_doc x.conditional_question in
    let con = get_doc x.conditional_consequence in
    let col = get_doc x.conditional_colon in
    let alt = get_doc x.conditional_alternative in
    (* TODO: Could this be improved? *)
    group_doc ( tst ^| qm ^| con ^| col ^| alt )
  | FunctionCallExpression x ->
    let receiver = get_doc x.function_call_receiver in
    let lparen = get_doc x.function_call_lparen in
    let args = get_doc x.function_call_arguments in
    let rparen = get_doc x.function_call_rparen in
    receiver ^^^ lparen ^^^ args ^^^ rparen
  | ParenthesizedExpression x ->
    let left = get_doc x.paren_expr_left_paren in
    let right = get_doc x.paren_expr_right_paren in
    let expr = get_doc x.paren_expr in
    indent_block_no_space left expr right indt
  | BracedExpression x ->
    let left = get_doc x.braced_expr_left_brace in
    let right = get_doc x.braced_expr_right_brace in
    let expr = get_doc x.braced_expr in
    indent_block_no_space left expr right indt
  | ListExpression
    { list_keyword; list_left_paren; list_members; list_right_paren } ->
    let keyword = get_doc list_keyword in
    let left_paren = get_doc list_left_paren in
    let members = get_doc list_members in
    let right_paren = get_doc list_right_paren in
    let left = group_doc (keyword ^| left_paren) in
    indent_block_no_space left members right_paren indt
  | CollectionLiteralExpression x ->
    let token = get_doc x.collection_literal_name in
    let left_brace = get_doc x.collection_literal_left_brace in
    let expression_list = get_doc x.collection_literal_initialization_list in
    let right_brace = get_doc x.collection_literal_right_brace in
    token ^| left_brace ^| expression_list ^| right_brace
  | ObjectCreationExpression x ->
    let n = get_doc x.object_creation_new in
    let c = get_doc x.object_creation_class in
    let l = get_doc x.object_creation_lparen in
    let a = get_doc x.object_creation_arguments in
    let r = get_doc x.object_creation_rparen in
    n ^| c ^^^ l ^^^ a ^^^ r
  | FieldInitializer
    { field_initializer_name; field_initializer_arrow;
      field_initializer_value }->
    let n = get_doc field_initializer_name in
    let a = get_doc field_initializer_arrow in
    let v = get_doc field_initializer_value in
    n ^| a ^| v
  | ShapeExpression
    { shape_expression_keyword; shape_expression_left_paren;
      shape_expression_fields; shape_expression_right_paren } ->
    let sh = get_doc shape_expression_keyword in
    let lp = get_doc shape_expression_left_paren in
    let fs = get_doc shape_expression_fields in
    let rp = get_doc shape_expression_right_paren in
    sh ^| lp ^^^ fs ^^^ rp
  | ArrayCreationExpression x ->
    let left_bracket = get_doc x.array_creation_left_bracket in
    let right_bracket = get_doc x.array_creation_right_bracket in
    let members = get_doc x.array_creation_members in
    indent_block_no_space left_bracket members right_bracket indt
  | ArrayIntrinsicExpression x ->
    let keyword = get_doc x.array_intrinsic_keyword in
    let left = get_doc x.array_intrinsic_left_paren in
    let right = get_doc x.array_intrinsic_right_paren in
    let members = get_doc x.array_intrinsic_members in
    let left_part = group_doc (keyword ^^| left) in
    indent_block_no_space left_part members right indt
  | ElementInitializer x ->
    let k = get_doc x.element_key in
    let a = get_doc x.element_arrow in
    let v = get_doc x.element_value in
    k ^| a ^| v
  | SubscriptExpression x ->
    let receiver = get_doc x.subscript_receiver in
    let left = get_doc x.subscript_left in
    let index = get_doc x.subscript_index in
    let right = get_doc x.subscript_right in
    receiver ^^^ left ^^^ index ^^^ right
  | AwaitableCreationExpression x ->
    let async = get_doc x.awaitable_async in
    let stmt = x.awaitable_compound_statement in
    handle_compound_brace_prefix_indent async stmt indt
  | XHPExpression x ->
    let left = get_doc x.xhp_open in
    let expr = get_doc x.xhp_body in
    let right = get_doc x.xhp_close in
    left ^^^ expr ^^^ right
  | XHPOpen
    { xhp_open_name; xhp_open_attributes; xhp_open_right_angle } ->
    let name = get_doc xhp_open_name in
    let attrs = get_doc xhp_open_attributes in
    let close = get_doc xhp_open_right_angle in
    group_doc (group_doc (indent_doc name attrs indt) ^| close)
  | XHPAttribute
    { xhp_attribute_name; xhp_attribute_equal; xhp_attribute_expr }->
    let name = get_doc xhp_attribute_name in
    let equals = get_doc xhp_attribute_equal in
    let expr = get_doc xhp_attribute_expr in
    group_doc (group_doc (name ^^| equals) ^^| expr)
  | XHPClose x ->
    let left = get_doc x.xhp_close_left_angle in
    let name = get_doc x.xhp_close_name in
    let right = get_doc x.xhp_close_right_angle in
    left ^^^ name ^^^ right
  | TypeConstant x ->
    let left = get_doc x.type_constant_left_type in
    let right = get_doc x.type_constant_right_type in
    let separator = get_doc x.type_constant_separator in
    left ^^^ separator ^^^ right
  | SimpleTypeSpecifier x -> get_doc x.simple_type_specifier
  | TypeConstraint { constraint_keyword; constraint_type } ->
    let k = get_doc constraint_keyword in
    let t = get_doc constraint_type in
    k ^| t
  | TypeParameter x ->
    let variance = get_doc x.type_variance_opt in
    let name = get_doc x.type_name in
    let constraints = get_doc x.type_constraint_list_opt in
    variance ^^^ name ^| constraints
  | NullableTypeSpecifier x ->
    let qm = get_doc x.nullable_question in
    let ty = get_doc x.nullable_type in
    qm ^^^ ty
  | SoftTypeSpecifier x ->
    let a = get_doc x.soft_at in
    let t = get_doc x.soft_type in
    a ^^^ t
  | GenericTypeSpecifier x ->
    let name = get_doc x.generic_class_type in
    let argument = get_doc x.generic_arguments in
    group_doc (indent_doc_no_space name argument indt)
  | VectorTypeSpecifier x ->
    let ar = get_doc x.vector_array in
    let la = get_doc x.vector_left_angle in
    let ty = get_doc x.vector_type in
    let ra = get_doc x.vector_right_angle in
    ar ^^^ la ^^^ ty ^^^ ra
  | MapTypeSpecifier x ->
    let ar = get_doc x.map_array in
    let la = get_doc x.map_left_angle in
    let kt = get_doc x.map_key in
    let co = get_doc x.map_comma in
    let vt = get_doc x.map_value in
    let ra = get_doc x.map_right_angle in
    ar ^^^ la ^^^ kt ^^^ co ^| vt ^^^ ra
  | ClosureTypeSpecifier x ->
    let olp = get_doc x.closure_outer_left_paren in
    let fnc = get_doc x.closure_function in
    let ilp = get_doc x.closure_inner_left_paren in
    let pts = get_doc x.closure_parameter_types in
    let irp = get_doc x.closure_inner_right_paren in
    let col = get_doc x.closure_colon in
    let ret = get_doc x.closure_return_type in
    let orp = get_doc x.closure_outer_right_paren in
    olp ^^^ fnc ^^| ilp ^^^ pts ^^^ irp ^^^ col ^^^ ret ^^^ orp
  | ClassnameTypeSpecifier x ->
    let cn = get_doc x.classname_classname in
    let la = get_doc x.classname_left_angle in
    let ty = get_doc x.classname_type in
    let ra = get_doc x.classname_right_angle in
    cn ^^^ la ^^^ ty ^^^ ra
  | FieldSpecifier x ->
    let n = get_doc x.field_name in
    let a = get_doc x.field_arrow in
    let t = get_doc x.field_type in
    n ^| a ^| t
  | ShapeTypeSpecifier
    { shape_type_keyword; shape_type_left_paren;
      shape_type_fields; shape_type_right_paren } ->
    let sh = get_doc shape_type_keyword in
    let lp = get_doc shape_type_left_paren in
    let fs = get_doc shape_type_fields in
    let rp = get_doc shape_type_right_paren in
    sh ^| lp ^^^ fs ^^^ rp
  | TypeArguments x ->
    let left = get_doc x.type_arguments_left_angle in
    let right = get_doc x.type_arguments_right_angle in
    let args = get_doc x.type_arguments in
    indent_block_no_space left args right indt
  | TypeParameters x ->
    let left = get_doc x.type_parameters_left_angle in
    let params = get_doc x.type_parameters in
    let right = get_doc x.type_parameters_right_angle in
    indent_block_no_space left params right indt
  | TupleTypeSpecifier x ->
    let left = get_doc x.tuple_left_paren in
    let types = get_doc x.tuple_types in
    let right = get_doc x.tuple_right_paren in
    indent_block_no_space left types right indt
  (* this ideally should never be called *)
  | CaseStatement x ->
    let keyword = get_doc x.case_keyword in
    let expr = get_doc x.case_expr in
    let colon = get_doc x.case_colon in
    let statement = x.case_stmt in
    let front_part = keyword ^^^ space ^^^ expr ^^^ colon in
    handle_compound_brace_prefix_indent front_part statement indt
  | DefaultStatement x ->
    let keyword = get_doc x.default_keyword in
    let colon = get_doc x.default_colon in
    let statement = x.default_stmt in
    let front_part = keyword ^^^ colon in
    handle_compound_brace_prefix_indent front_part statement indt
  | ReturnStatement x ->
    let keyword = get_doc x.return_keyword in
    let expr = get_doc x.return_expr in
    let semicolon = get_doc x.return_semicolon in
    let back_part = expr ^^^ semicolon in
    group_doc (indent_doc keyword back_part indt)
  | ThrowStatement x ->
    let keyword = get_doc x.throw_keyword in
    let expr = get_doc x.throw_expr in
    let semicolon = get_doc x.throw_semicolon in
    let back_part = expr ^^^ semicolon in
    group_doc (indent_doc keyword back_part indt)
  | BreakStatement x ->
    let b = get_doc x.break_keyword in
    let l = get_doc x.break_level in
    let s = get_doc x.break_semicolon in
    if is_missing x.break_level then group_doc (b ^^^ l ^^^ s)
    else group_doc (b ^| l ^^^ s)
  | ContinueStatement x ->
    let c = get_doc x.continue_keyword in
    let l = get_doc x.continue_level in
    let s = get_doc x.continue_semicolon in
    if is_missing x.continue_level then group_doc (c ^^^ l ^^^ s)
    else group_doc (c ^| l ^^^ s)
  | FunctionStaticStatement x ->
    let st = get_doc x.static_static in
    let ds = get_doc x.static_declarations in
    let se = get_doc x.static_semicolon in
    st ^| ds ^^^ se
  | StaticDeclarator
    { static_name; static_initializer } ->
    let n = get_doc static_name in
    let i = get_doc static_initializer in
    group_doc (n ^| i)
  | EchoStatement x ->
    let echo = get_doc x.echo_keyword in
    let expr_list = get_doc x.echo_expression_list in
    let semicolon = get_doc x.echo_semicolon in
    echo ^| expr_list ^^^ semicolon
  | SimpleInitializer
    { simple_initializer_equal; simple_initializer_value } ->
    let e = get_doc simple_initializer_equal in
    let v = get_doc simple_initializer_value in
    group_doc (e ^| v)

(* sep is the compulsory separator separating the children in the list *)
and get_from_children_with_sep sep children =
  let fold_fun acc el = (acc ^^^ sep) ^| get_doc el in
  group_doc (List.fold_left fold_fun (make_simple nil) children)
and get_from_children node = get_from_children_with_sep (make_simple nil) node
(* if it is a compound statement, the curly braces do not need indent *)
and peek_and_decide_indent x default =
  match syntax x with
  | CompoundStatement _ -> 0
  | _ -> default
(* Generate documents for a switch statement *)
and handle_switch prefix switch =
  match syntax switch.switch_compound_statement with
  | CompoundStatement x ->
    let left = get_doc x.compound_left_brace in
    let left = group_doc (prefix ^| left) in
    let right = get_doc x.compound_right_brace in
    let body =
      let compound_body = x.compound_statements in
      match syntax compound_body with
      | SyntaxList lst -> handle_switch_lists lst
      | _ -> get_doc compound_body
    in
    indent_block_no_space left body right indt |> add_break
  | _ -> prefix ^| get_doc switch.switch_compound_statement |> add_break
(* specifically identify case chunks and generate docs from the list of
 * statements inside the compound statement of the switch statements *)
and handle_switch_lists lst =
  (* fold on a reversed statement list, if the element is not a case or default
   * label, then add the element to the [current] chunk. Otherwise, group the
   * current chunks together with the label, resulting in an indented block *)
  let fold_fun (current, docs) node =
    match syntax node with
    | CaseStatement x ->
      let keyword = get_doc x.case_keyword in
      let expr = get_doc x.case_expr in
      let colon = get_doc x.case_colon in
      let front_part = keyword ^^^ space ^^^ expr ^^^ colon |> add_break in
      let case_chunk = SyntaxList (x.case_stmt :: current) in
      let new_list = make case_chunk (value node) in
      let end_part = get_doc new_list in
      let new_chunk = group_doc (indent_doc front_part end_part indt) in
      ([], new_chunk :: docs)
    | DefaultStatement x ->
      let keyword =  get_doc x.default_keyword in
      let colon = get_doc x.default_colon in
      let front_part = keyword ^^^ colon |> add_break in
      let default_chunk = SyntaxList (x.default_stmt :: current) in
      let new_list = make default_chunk (value node) in
      let end_part = get_doc new_list in
      let new_chunk = group_doc (indent_doc front_part end_part indt) in
      ([], new_chunk :: docs)
    (* if this is not a case statement, add it to current *)
    | _ -> (node :: current, docs)
  in
  let (rest, docs) = List.fold_left fold_fun ([], []) (List.rev lst) in
  let rest_list = SyntaxList rest in
  (* TODO better interface to do this? *)
  let rest_node = make rest_list Syntax.EditableSyntaxValue.NoValue in
  let rest_doc = get_doc rest_node in
  let all_docs = rest_doc :: docs in
  List.fold_left (^|) (make_simple nil) all_docs
(* puts [prefix] on the same line as a compound brace. If the statement is not
 * compound, put an optional newline and group the result *)
and handle_compound_inline_brace prefix statement postfix =
  match syntax statement with
  | CompoundStatement compound_stmt ->
  let left = get_doc compound_stmt.compound_left_brace in
  let right = get_doc compound_stmt.compound_right_brace in
  let statement = get_doc compound_stmt.compound_statements in
  let prefix = group_doc (prefix ^| left) in
  let postfix = group_doc (right ^| postfix) in
  indent_block prefix statement postfix indt
  | _ -> group_doc (prefix ^| get_doc statement ^| postfix)
(* keep open brace of compound statement on the same line as the prefix.
 * If statement is not a compound statement, then indent it with [indt] *)
and handle_compound_brace_prefix_indent prefix statement indt =
  if is_compound_statement statement then
    handle_compound_inline_brace prefix statement missing
  else
    group_doc (indent_doc prefix (get_doc statement) indt)

let pretty_print node =
  let empty_string = make_simple (text "") in
  let to_print = node |> get_doc |> add_break in
  let to_print = to_print ^| empty_string in
  let to_print = combine to_print in
  pretty 0 to_print
