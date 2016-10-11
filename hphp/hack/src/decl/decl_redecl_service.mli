(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Reordered_argument_collections
open Typing_deps

val redo_type_decl :
  Worker.t list option ->
  bucket_size:int ->
  TypecheckerOptions.t ->
  FileInfo.fast ->
  Errors.t * Relative_path.Set.t * DepSet.t * DepSet.t

(**
 * Exposed for tests only!
 * For a set of classes, return all the declared classes that share their class
 * elements (see Decl_class_elements).
 * Not for general use case since it doesn't use lazy decl and makes sense only
 * in a very particular use case of invalidate_type_decl.
 *)
val get_dependent_classes :
  Worker.t list option ->
  bucket_size:int ->
  FileInfo.t Relative_path.Map.t ->
  SSet.t ->
  SSet.t

val invalidate_type_decl :
  Worker.t list option ->
  FileInfo.t Relative_path.Map.t ->
  bucket_size:int ->
  (* Invalidating classes also invalidates their elements
   * (see Decl_class_elements), which might be shared with other classes.
   * We need to remove all of them too to avoid dangling references - the only
   * exception is if we are sure that removed classes will be immediately
   * redeclared, before anyone tries to access their elements *)
  invalidate_dependent_classes:bool ->
  FileInfo.fast ->
  unit
