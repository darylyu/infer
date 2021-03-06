(*
* Copyright (c) 2009 -2013 Monoidics ltd.
* Copyright (c) 2013 - Facebook.
* All rights reserved.
*)

(** Classify bugs into buckets *)

module L = Logging
module F = Format
open Utils

let verbose = Config.trace_error

(** check if the error was reported inside a nested loop
the implementation is approximate: check if the last two visits to a loop were entering loops *)
let check_nested_loop path pos_opt =
  let trace_length = ref 0 in
  let loop_visits_log = ref [] in
  let in_nested_loop () = match !loop_visits_log with
    | true :: true :: _ ->
        if !verbose then L.d_strln "in nested loop";
        true (* last two loop visits were entering loops *)
    | _ -> false in
  let do_node_caller node = match Cfg.Node.get_kind node with
    | Cfg.Node.Prune_node (b, (Sil.Ik_dowhile | Sil.Ik_for | Sil.Ik_while), _) ->
    (* if !verbose then L.d_strln ((if b then "enter" else "exit") ^ " node " ^ (string_of_int (Cfg.Node.get_id node))); *)
        loop_visits_log := b :: !loop_visits_log
    | _ -> () in
  let do_any_node level node =
    incr trace_length;
    (* L.d_strln ("level " ^ string_of_int level ^ " (Cfg.Node.get_id node) " ^ string_of_int nid); *)
    () in
  let f level p session exn_opt =
    let node = Paths.Path.curr_node p in
    do_any_node level node;
    if level = 0 then do_node_caller node;
    () in
  Paths.Path.iter_longest_sequence f pos_opt path;
  in_nested_loop ()

(** Check that we know where the value was last assigned, and that there is a local access instruction at that line. **)
let check_access access_opt =
  let find_bucket line_number null_case_flag =
    let find_formal_ids node = (* find ids obtained by a letref on a formal parameter *)
      let node_instrs = Cfg.Node.get_instrs node in
      let formals = Cfg.Procdesc.get_formals (Cfg.Node.get_proc_desc node) in
      let formal_names = list_map (fun (s, _) -> Mangled.from_string s) formals in
      let is_formal pvar =
        let name = Sil.pvar_get_name pvar in
        list_exists (Mangled.equal name) formal_names in
      let formal_ids = ref [] in
      let process_formal_letref = function
        | Sil.Letderef (id, Sil.Lvar pvar, _, _) ->
            let is_java_this =
              !Sil.curr_language = Sil.Java && Sil.pvar_is_this pvar in
            if not is_java_this && is_formal pvar then formal_ids := id :: !formal_ids
        | _ -> () in
      list_iter process_formal_letref node_instrs;
      !formal_ids in
    let formal_param_used_in_call = ref false in
    let has_call_or_sets_null node =
      let rec exp_is_null = function
        | Sil.Const (Sil.Cint n) -> Sil.Int.iszero n
        | Sil.Cast (_, e) -> exp_is_null e
        | _ -> false in
      let filter = function
        | Sil.Call (_, _, etl, _, _) ->
            let formal_ids = find_formal_ids node in
            let arg_is_formal_param (e, t) = match e with
              | Sil.Var id -> list_exists (Ident.equal id) formal_ids
              | _ -> false in
            if list_exists arg_is_formal_param etl then formal_param_used_in_call := true;
            true
        | Sil.Set (_, _, e, _) -> exp_is_null e
        | _ -> false in
      list_exists filter (Cfg.Node.get_instrs node) in
    let local_access_found = ref false in
    let do_node node =
      if (Cfg.Node.get_loc node).Sil.line = line_number && has_call_or_sets_null node then
        begin
          local_access_found := true
        end in
    let path, pos_opt = State.get_path () in
    Paths.Path.iter_all_nodes_nocalls do_node path;
    if !local_access_found then
      let bucket =
        if null_case_flag then Localise.BucketLevel.b5 else
        if check_nested_loop path pos_opt then Localise.BucketLevel.b3
        else if !formal_param_used_in_call then Localise.BucketLevel.b2
        else Localise.BucketLevel.b1 in
      Some bucket
    else None in

  match access_opt with
  | Some (Localise.Last_assigned (n, ncf)) ->
      find_bucket n ncf
  | Some (Localise.Returned_from_call n) ->
      find_bucket n false
  | Some (Localise.Last_accessed (n, is_nullable)) when is_nullable ->
      Some Localise.BucketLevel.b1
  | _ -> None

let classify_access desc access_opt =
  L.d_strln "Doing classification";
  let show_in_message = !Config.show_buckets in
  match check_access access_opt with
  | None -> Localise.error_desc_set_bucket desc Localise.BucketLevel.b5 show_in_message
  | Some bucket -> Localise.error_desc_set_bucket desc bucket show_in_message
