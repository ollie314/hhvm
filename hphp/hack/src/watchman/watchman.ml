(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 **)

open Core
open Utils

(*
 * Module for us to interface with Watchman, a file watching service.
 * https://facebook.github.io/watchman/
 *
 * TODO:
 *   * Connect directly to the Watchman server socket instead of spawning
 *     a client process each time
 *   * Use the BSER protocol for enhanced performance
 *)

exception Watchman_error of string
exception Timeout
exception Read_payload_too_long

let debug = false

let sync_file_extension = "tmp_sync"

(** TODO: support git. *)
let vcs_tmp_dir = ".hg"

let crash_marker_path root =
  let root_name = Path.slash_escaped_string_of_path root in
  Filename.concat GlobalConfig.tmp_dir (spf ".%s.watchman_failed" root_name)

type init_settings = {
  subscribe_to_changes: bool;
  (** Seconds used for init timeout - will be reused for reinitialization. *)
  init_timeout: int;
  root: Path.t;
}

type dead_env = {
  (** Will reuse original settings to reinitializing watchman subscription. *)
  prior_settings : init_settings;
  reinit_attempts: int;
  dead_since: float;
}

type env = {
  settings : init_settings;
  socket: Timeout.in_channel * out_channel;
  watch_root: string;
  relative_path: string;
  (* See https://facebook.github.io/watchman/docs/clockspec.html *)
  mutable clockspec: string;
}

let dead_env_from_alive env =
  {
    prior_settings = env.settings;
    dead_since = Unix.time ();
    reinit_attempts = 0;
  }

type 'a changes =
  | Watchman_unavailable
  | Watchman_pushed of 'a
  | Watchman_synchronous of 'a

type watchman_instance =
  (** Indicates a dead watchman instance (most likely due to chef upgrading,
   * reconfiguration, or a user terminating watchman) detected by,
   * for example, a pipe error.
   *
   * TODO: Currently fallback to a Watchman_dead is only handled in calls
   * wrapped by the with_crash_record. Pipe errors elsewhere (for example
   * during exec) will still result in Hack exiting. Need to cover those
   * cases too. *)
  | Watchman_dead of dead_env
  | Watchman_alive of env

let get_root_path instance = match instance with
  | Watchman_dead dead_env -> dead_env.prior_settings.root
  | Watchman_alive env -> env.settings.root

(* Some JSON processing helpers *)
module J = struct
  let try_get_val key json =
    let obj = Hh_json.get_object_exn json in
    List.Assoc.find obj key

  let get_string_val key ?default json =
    let v = try_get_val key json in
    match v, default with
    | Some v, _ -> Hh_json.get_string_exn v
    | None, Some def -> def
    | None, None -> raise Not_found

  let get_array_val key ?default json =
    let v = try_get_val key json in
    match v, default with
    | Some v, _ -> Hh_json.get_array_exn v
    | None, Some def -> def
    | None, None -> raise Not_found

  let strlist args =
    Hh_json.JSON_Array begin
      List.map args (fun arg -> Hh_json.JSON_String arg)
    end

  (* Prepend a string to a JSON array of strings. pred stands for predicate,
   * because that's how they are typically represented in watchman. See e.g.
   * https://facebook.github.io/watchman/docs/expr/allof.html *)
  let pred name args =
    let open Hh_json in
    JSON_Array (JSON_String name :: args)
end

(*****************************************************************************)
(* JSON methods. *)
(*****************************************************************************)

let clock root = J.strlist ["clock"; root]

type watch_command = Subscribe | Query

let request_json
    ?(extra_kv=[]) ?(extra_expressions=[]) watchman_command env =
  let open Hh_json in
  let command = begin match watchman_command with
    | Subscribe -> "subscribe"
    | Query -> "query" end in
  let header =
    [JSON_String command ; JSON_String env.watch_root] @
      begin
        match watchman_command with
        | Subscribe -> [JSON_String "hh_type_check_watcher"]
        | _ -> []
      end in
  let directives = [
    JSON_Object (extra_kv @ [
      "fields", J.strlist ["name"];
      "relative_root", JSON_String env.relative_path;
      "expression", J.pred "allof" @@ (extra_expressions @ [
        J.strlist ["type"; "f"];
        J.pred "anyof" @@ [
          J.strlist ["name"; ".hhconfig"];
          J.pred "anyof" @@ [
            J.strlist ["suffix"; "php"];
            J.strlist ["suffix"; "phpt"];
            J.strlist ["suffix"; "hh"];
            J.strlist ["suffix"; "hhi"];
            J.strlist ["suffix"; sync_file_extension];
            J.strlist ["suffix"; "xhp"];
            (* FIXME: This is clearly wrong, but we do it to match the
             * behavior on the server-side. We need to investigate if
             * tracking js files is truly necessary.
             *)
            J.strlist ["suffix"; "js"];
          ];
        ];
        J.pred "not" @@ [
          J.pred "anyof" @@ [
            (** We don't exclude the .hg directory, because we touch unique
             * files there to support synchronous queries. *)
            J.strlist ["dirname"; ".git"];
            J.strlist ["dirname"; ".svn"];
          ]
        ]
      ])
    ])
  ] in
  let request = JSON_Array (header @ directives) in
  request

let all_query env =
  request_json
    ~extra_expressions:([Hh_json.JSON_String "exists"])
    Query env

let since_query env =
  request_json
    ~extra_kv: ["since", Hh_json.JSON_String env.clockspec]
    Query env

let subscribe env = request_json
                      ~extra_kv:["since", Hh_json.JSON_String env.clockspec ;
                                 "defer", J.strlist ["hg.update"]]
                      Subscribe env

let watch_project root = J.strlist ["watch-project"; root]

(* See https://facebook.github.io/watchman/docs/cmd/version.html *)
let capability_check ?(optional=[]) required =
  let open Hh_json in
  JSON_Array begin
    [JSON_String "version"] @ [
      JSON_Object [
        "optional", J.strlist optional;
        "required", J.strlist required;
      ]
    ]
  end

(*****************************************************************************)
(* Handling requests and responses. *)
(*****************************************************************************)

let read_with_timeout timeout ic =
  let fd = Timeout.descr_of_in_channel ic in
  match Unix.select [fd] [] [] timeout with
    | [ready_fd], _, _ when ready_fd = fd-> begin
     let max_read_time = 20 in
     Timeout.with_timeout ~timeout:max_read_time
       ~do_:(fun t -> Timeout.input_line ~timeout:t ic)
       ~on_timeout:begin fun _ ->
                     EventLogger.watchman_timeout ();
                     raise Timeout
                   end
    end
    | _, _, _ ->
      EventLogger.watchman_timeout ();
      raise Timeout

let assert_no_error obj =
  (try
     let warning = J.get_string_val "warning" obj in
     EventLogger.watchman_warning warning;
     Hh_logger.log "Watchman warning: %s\n" warning
   with Not_found -> ());
  (try
     let error = J.get_string_val "error" obj in
     EventLogger.watchman_error error;
     raise @@ Watchman_error error
   with Not_found -> ())

let sanitize_watchman_response output =
  if debug then Printf.eprintf "Watchman response: %s\n%!" output;
  let response =
    try Hh_json.json_of_string output
    with e ->
      Printf.eprintf "Failed to parse string as JSON: %s\n%!" output;
      raise e
  in
  assert_no_error response;
  response

let exec ?(timeout=120.0) (ic, oc) json =
  let json_str = Hh_json.(json_to_string json) in
  if debug then Printf.eprintf "Watchman request: %s\n%!" json_str ;
  output_string oc json_str;
  output_string oc "\n";
  flush oc ;
  sanitize_watchman_response (read_with_timeout timeout ic)

(*****************************************************************************)
(* Initialization, reinitialization, and crash-tracking. *)
(*****************************************************************************)

let get_sockname timeout =
  let ic =
    Timeout.open_process_in "watchman"
    [| "watchman"; "get-sockname"; "--no-pretty" |] in
  let output = read_with_timeout (float_of_int timeout) ic in
  assert (Timeout.close_process_in ic = Unix.WEXITED 0);
  let json = Hh_json.json_of_string output in
  J.get_string_val "sockname" json

let with_crash_record_exn root source f =
  try f ()
  with e ->
    close_out @@ open_out @@ crash_marker_path root;
    Hh_logger.exc ~prefix:("Watchman " ^ source ^ ": ") e;
    raise e

let with_crash_record_opt root source f =
  Option.try_with (fun () -> with_crash_record_exn root source f)

let init { init_timeout; subscribe_to_changes; root } =
  with_crash_record_opt root "init" @@ fun () ->
  let root_s = Path.to_string root in
  let sockname = get_sockname init_timeout in
  let socket = Timeout.open_connection (Unix.ADDR_UNIX sockname) in
  ignore @@ exec socket (capability_check ["relative_root"]);
  let response = exec socket (watch_project root_s) in
  let watch_root = J.get_string_val "watch" response in
  let relative_path = J.get_string_val "relative_path" ~default:"" response in

  let clockspec =
    exec socket (clock watch_root) |> J.get_string_val "clock" in
  let env = {
    settings = {
      init_timeout;
      subscribe_to_changes;
      root;
    };
    socket;
    watch_root;
    relative_path;
    clockspec;
  } in
  if subscribe_to_changes then (ignore @@ exec env.socket (subscribe env)) ;
  env

let has_input timeout (in_channel, _) =
  let fd = Timeout.descr_of_in_channel in_channel in
  match Unix.select [fd] [] [] timeout with
    | [_], _, _ -> true
    | _ -> false

let no_updates_response clockspec =
  let timeout_str = "{\"files\":[]," ^ "\"clock\":\"" ^ clockspec ^ "\"}" in
  Hh_json.json_of_string timeout_str

let poll_for_updates ?timeout env =
  let timeout = Option.value timeout ~default:0.0 in
  let ready = has_input timeout env.socket in
  if not ready then
    if timeout = 0.0 then no_updates_response env.clockspec
    else raise Timeout
  else
  let timeout = 20 in
  try
    let output = begin
      let in_channel, _  = env.socket in
      (* Use the timeout mechanism to limit maximum time to read payload (cap
       * data size). *)
      Timeout.with_timeout
        ~do_: (fun t -> Timeout.input_line ~timeout:t in_channel)
        ~timeout
        ~on_timeout:begin fun _ -> () end
    end in
    sanitize_watchman_response output
  with
  | Timeout.Timeout ->
    let () = Hh_logger.log "Watchman.poll_for_updates timed out" in
    raise Read_payload_too_long
  | _ as e ->
    raise e

let extract_file_names env json =
  let files = J.get_array_val "files" json in
  let files = List.map files begin fun json ->
    let s = Hh_json.get_string_exn json in
    let abs =
      Filename.concat env.watch_root @@
      Filename.concat env.relative_path s in
    abs
  end in
  files

let within_backoff_time attempts time =
  let offset = 4.0 *. (2.0 ** float (if attempts > 3 then 3 else attempts)) in
  (Unix.time ()) >= time +. offset

let maybe_restart_instance instance = match instance with
  | Watchman_alive _ -> instance
  | Watchman_dead dead_env ->
    if within_backoff_time dead_env.reinit_attempts dead_env.dead_since then
      let () =
        Hh_logger.log "Attemping to reestablish watchman subscription" in
      match init dead_env.prior_settings with
      | None ->
        Hh_logger.log "Reestablishing watchman subscription failed.";
        EventLogger.watchman_connection_reestablishment_failed ();
        Watchman_dead { dead_env with
          reinit_attempts = dead_env.reinit_attempts + 1 }
      | Some env ->
        Hh_logger.log "Watchman connection reestablished.";
        EventLogger.watchman_connection_reestablished ();
        Watchman_alive env
    else
      instance

let call_on_instance instance source f =
  let instance = maybe_restart_instance instance in
  match instance with
  | Watchman_dead _ ->
    instance, Watchman_unavailable
  | Watchman_alive env -> begin
    try
      instance, with_crash_record_exn env.settings.root source (fun () -> f env)
    with
      | Sys_error("Broken pipe") ->
        Hh_logger.log "Watchman Pipe broken.";
        EventLogger.watchman_died_caught ();
        Watchman_dead (dead_env_from_alive env), Watchman_unavailable
      | Sys_error("Connection reset by peer") ->
        Hh_logger.log "Watchman connection reset by peer.";
        EventLogger.watchman_died_caught ();
        Watchman_dead (dead_env_from_alive env), Watchman_unavailable
      | End_of_file ->
        Hh_logger.log "Watchman connection End_of_file. Closing channel";
        let ic, _ = env.socket in
        Timeout.close_in ic;
        EventLogger.watchman_died_caught ();
        Watchman_dead (dead_env_from_alive env), Watchman_unavailable
      | Read_payload_too_long ->
        Hh_logger.log "Watchman reading payload too long. Closing channel";
        let ic, _ = env.socket in
        Timeout.close_in ic;
        EventLogger.watchman_died_caught ();
        Watchman_dead (dead_env_from_alive env), Watchman_unavailable
      | Timeout as e ->
        raise e
      | e ->
        let msg = Printexc.to_string e in
        EventLogger.watchman_uncaught_failure msg;
        Exit_status.(exit Watchman_failed)
  end

let get_all_files env =
  try with_crash_record_exn env.settings.root "get_all_files"  @@ fun () ->
    let response = exec env.socket (all_query env) in
    env.clockspec <- J.get_string_val "clock" response;
    extract_file_names env response with
    | _ ->
      Exit_status.(exit Watchman_failed)

let transform_changes_response env data =
    env.clockspec <- J.get_string_val "clock" data;
    set_of_list @@ extract_file_names env data

let random_filepath root =
  let root_name = Path.to_string root in
  let dir = Filename.concat root_name vcs_tmp_dir in
  let name = Random_id.(short_string_with_alphabet alphanumeric_alphabet) in
  Filename.concat dir (spf ".%s.%s" name sync_file_extension)

let get_changes ?deadline instance =
  let timeout = Option.map deadline ~f:(fun deadline ->
    let timeout = deadline -. (Unix.time ()) in
    max timeout 0.0
  ) in
  call_on_instance instance "get_changes" @@ fun env ->
    let response = begin
        if env.settings.subscribe_to_changes
        then Watchman_pushed (poll_for_updates ?timeout env)
        else Watchman_synchronous (exec ?timeout env.socket (since_query env))
    end in
    match response with
    | Watchman_unavailable -> Watchman_unavailable
    | Watchman_pushed data ->
      Watchman_pushed (transform_changes_response env data)
    | Watchman_synchronous data ->
      Watchman_synchronous (transform_changes_response env data)

let rec get_changes_until_file_sync deadline syncfile instance acc_changes =
  if Unix.time () >= deadline then raise Timeout else ();
  let instance, changes = get_changes ~deadline instance in
  match changes with
  | Watchman_unavailable ->
    (** We don't need to use Retry_with_backoff_exception because there is
     * exponential backoff built into get_changes to restart the watchman
     * instance. *)
    get_changes_until_file_sync
      deadline syncfile instance acc_changes (** Not in 4.01 yet [@tailcall] *)
  | Watchman_synchronous changes
  | Watchman_pushed changes ->
    let acc_changes = SSet.union acc_changes changes in
    if SSet.mem syncfile changes then
      instance, acc_changes
    else
      get_changes_until_file_sync deadline syncfile instance acc_changes

(** Raise this exception together with a with_retries_until_deadline call to
 * make use of its exponential backoff machinery. *)
exception Retry_with_backoff_exception

(** Call "f instance temp_file_name" with a random temporary file created
 * before f and deleted after f. *)
let with_random_temp_file instance f =
  let root = get_root_path instance in
  let temp_file = random_filepath root in
  let ic = try Some ( open_out_gen [Open_creat; Open_excl] 555 temp_file) with
    | _ -> None
  in
  match ic with
  | None ->
    (** Failed to create temp file. Retry with exponential backoff. *)
    raise Retry_with_backoff_exception
  | Some ic ->
    let () = close_out ic in
    let result = f instance temp_file in
    let () = Sys.remove temp_file in
    result

(** Call f with retries if it throws Retry_with_backoff_exception,
 * using exponential backoff between attempts.
 *
 * Raise Timeout if deadline arrives. *)
let rec with_retries_until_deadline ~attempt instance deadline f =
  if Unix.time () > deadline then raise Timeout else ();
  let max_wait_time = 10.0 in
  try f instance with
    | Retry_with_backoff_exception ->
      let () = if Unix.time () > deadline then raise Timeout else () in
      let wait_time = min max_wait_time (2.0 ** (float_of_int attempt)) in
      let () = ignore @@ Unix.select [] [] [] wait_time in
      with_retries_until_deadline ~attempt:(attempt + 1) instance deadline f

let get_changes_synchronously ~(timeout:int) instance =
  (** Reading uses Timeout.with_timeout, which is not re-entrant. So
   * we can't use that out here. *)
  let deadline = Unix.time () +. (float_of_int timeout) in
  with_retries_until_deadline ~attempt:0 instance deadline begin
    (** Lambda here must take an instance to avoid capturing the one in the
     * outer scope, which is the wrong one since it doesn't change between
     * restart attempts. *)
    fun instance ->
      with_random_temp_file instance begin fun instance sync_file ->
        let result =
          get_changes_until_file_sync deadline sync_file instance SSet.empty in
        result
      end
  end
