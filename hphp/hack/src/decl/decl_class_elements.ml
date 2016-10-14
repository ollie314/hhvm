(**
 * Copyright (c) 2016, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

open Core
open Decl_defs
open Decl_heap

type t = {
  props  : Props.KeySet.t;
  sprops : StaticProps.KeySet.t;
  meths  : Methods.KeySet.t;
  smeths : StaticMethods.KeySet.t;
}

let from_class {
  dc_name;
  dc_props;
  dc_sprops;
  dc_methods;
  dc_smethods;
  _;
} =
  let filter_inherited_elements (type a) (module EltHeap: SharedMem.NoCache
      with type key = string * string
       and type KeySet.t = a) elts =
    SMap.fold begin fun name { elt_origin = cls; _ } set ->
      if cls = dc_name then
        EltHeap.KeySet.add (cls, name) set
      else
        set
    end elts EltHeap.KeySet.empty
  in
  {
    props = filter_inherited_elements (module Props) dc_props;
    sprops = filter_inherited_elements (module StaticProps) dc_sprops;
    meths = filter_inherited_elements (module Methods) dc_methods;
    smeths = filter_inherited_elements (module StaticMethods) dc_smethods;
  }

let get_for_classes ~old classes =
  let get = if old then Decl_heap.Classes.get_old else Decl_heap.Classes.get in
  List.fold ~f:begin fun acc cls ->
    match get cls with
    | None -> acc
    | Some c -> SMap.add cls (from_class c) acc
  end classes ~init:SMap.empty

let oldify_batch {
  props;
  sprops;
  meths;
  smeths;
} =
  Props.oldify_batch props;
  StaticProps.oldify_batch sprops;
  Methods.oldify_batch meths;
  StaticMethods.oldify_batch smeths

let shelve_batch {
  props;
  sprops;
  meths;
  smeths;
} =
  Props.shelve_batch props;
  StaticProps.shelve_batch sprops;
  Methods.shelve_batch meths;
  StaticMethods.shelve_batch smeths

let remove_old_batch {
  props;
  sprops;
  meths;
  smeths;
} =
  Props.remove_old_batch props;
  StaticProps.remove_old_batch sprops;
  Methods.remove_old_batch meths;
  StaticMethods.remove_old_batch smeths

let unshelve_batch {
  props;
  sprops;
  meths;
  smeths;
} =
  Props.unshelve_batch props;
  StaticProps.unshelve_batch sprops;
  Methods.unshelve_batch meths;
  StaticMethods.unshelve_batch smeths

let remove_batch {
  props;
  sprops;
  meths;
  smeths;
} =
  Props.remove_batch props;
  StaticProps.remove_batch sprops;
  Methods.remove_batch meths;
  StaticMethods.remove_batch smeths

let oldify_all class_to_elems =
  SMap.iter begin fun cls elems ->
    Constructors.oldify_batch (SSet.singleton cls);
    oldify_batch elems
  end class_to_elems

let shelve_all class_to_elems =
  SMap.iter begin fun cls elems ->
    Constructors.shelve_batch (SSet.singleton cls);
    shelve_batch elems
  end class_to_elems

let unshelve_all class_to_elems =
  SMap.iter begin fun cls elems ->
    Constructors.unshelve_batch (SSet.singleton cls);
    unshelve_batch elems
  end class_to_elems

let remove_old_all class_to_elems =
  SMap.iter begin fun cls elems ->
    Constructors.remove_old_batch (SSet.singleton cls);
    remove_old_batch elems
  end class_to_elems

let remove_all class_to_elems =
  SMap.iter begin fun cls elems ->
    Constructors.remove_batch (SSet.singleton cls);
    remove_batch elems
  end class_to_elems

let unshelve_removed_elems classes =
  List.iter ~f:begin fun cls ->
    if not @@ Constructors.mem cls then
      Constructors.unshelve_batch (SSet.singleton cls);
    match Decl_heap.Classes.get_shelved cls with
    | None -> ()
    | Some c ->
      let { props; sprops; meths; smeths } = from_class c in
      let negate f x = not (f x) in
      let elems = {
        props = Props.(KeySet.filter (negate mem) props);
        sprops = StaticProps.(KeySet.filter (negate mem) sprops);
        meths = Methods.(KeySet.filter (negate mem) meths);
        smeths = StaticMethods.(KeySet.filter (negate mem) smeths);
      } in
      unshelve_batch elems
  end classes
