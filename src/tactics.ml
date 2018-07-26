(****************************************************************************)
(* Copyright (C) 2007-2009 Gacek                                            *)
(* Copyright (C) 2013-2016 Inria (Institut National de Recherche            *)
(*                         en Informatique et en Automatique)               *)
(*                                                                          *)
(* This file is part of Abella.                                             *)
(*                                                                          *)
(* Abella is free software: you can redistribute it and/or modify           *)
(* it under the terms of the GNU General Public License as published by     *)
(* the Free Software Foundation, either version 3 of the License, or        *)
(* (at your option) any later version.                                      *)
(*                                                                          *)
(* Abella is distributed in the hope that it will be useful,                *)
(* but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(* GNU General Public License for more details.                             *)
(*                                                                          *)
(* You should have received a copy of the GNU General Public License        *)
(* along with Abella.  If not, see <http://www.gnu.org/licenses/>.          *)
(****************************************************************************)

open Term
open Metaterm
open Unify
open Abella_types

open Extensions
  

(* Instantiation of polymorphic clauses and metaterms *)

let instantiate_poly_clause tysub vars head body =
  let vars = 
    List.map (fun (id,t) -> (id, inst_var_ty tysub t)) vars in
  let head = replace_term_vars vars 
               (inst_term_const_types tysub head) in
  let body = List.map 
               ((inst_term_const_types tysub) >> (replace_term_vars vars)) 
               body in
  (vars, head, body)

let instantiate_poly_def_clause tysub vars head body =
  let vars = 
    List.map (fun (id,t) -> (id, inst_var_ty tysub t)) vars in
  let head = replace_metaterm_vars vars 
               (inst_metaterm_const_types tysub head) in
  let body = body |> inst_metaterm_const_types tysub
                  |> replace_metaterm_vars vars in
  (vars, head, body)

let instantiate_poly_metaterm tysub t =
  let pvars = List.unique ((find_metaterm_poly_vars Logic t)
                           @ (find_metaterm_poly_vars Eigen t)
                           @ (find_metaterm_poly_vars Nominal t)) in
  let alist = 
    List.map (fun t -> (term_to_name t, inst_var_ty tysub t)) pvars in
  replace_metaterm_vars alist (inst_metaterm_const_types tysub t)



(* Variable naming utilities *)

let is_uninstantiated (x, vtm) =
  match observe (hnorm vtm) with
  | Var {Term.name=n; Term.tag=Eigen; _} when n = x -> true
  | _ -> false

let alist_to_used (_, t) = term_to_pair t

let freshen_clause ~used ~sr ?(support=[]) clause =
  let (tids, head, body) = clause in
  let (alist, vars) = fresh_raised_alist ~sr ~tag:Eigen ~used ~support tids in
  (List.map term_to_pair vars,
   replace_term_vars alist head,
   List.map (replace_term_vars alist) body)
  
(* let freshen_poly_clause ~tysub ~used ~sr ?(support=[]) clause =
 *   let (tids, head, body) = clause in
 *   let tids' = List.map 
 *     (fun (id,ty) -> (id, apply_sub_ty tysub ty)) tids in
 *   let head' = inst_term_ty tysub head in
 *   let body' = List.map (inst_term_ty tysub) body in
 *   freshen_clause ~sr ~support ~used (tids',head',body') *)

let freshen_def ~used ~sr ?(support=[]) head body =
  let tids = capital_tids [head] in
  let (alist, vars) = fresh_raised_alist ~sr ~tag:Eigen ~used ~support tids in
  (List.map term_to_pair vars,
   replace_term_vars alist head,
   replace_metaterm_vars alist body)

let term_vars_alist tag terms =
  List.map term_to_pair (find_var_refs tag terms)

let metaterm_vars_alist tag metaterm =
  term_vars_alist tag (collect_terms metaterm)

(* Freshening for Logic variables uses anonymous names *)

let fresh_nameless_alist ~support ~tag ~ts tids =
  let ntys = List.map (tc []) support in
  List.map
    (fun (x, ty) ->
       (x, app (fresh ~tag ts (tyarrow ntys ty)) support))
    tids

let freshen_nameless_clause ?(support=[]) ~ts clause =
  let (tids, head, body) = clause in
  let fresh_names = fresh_nameless_alist ~support ~tag:Logic ~ts tids in
  let fresh_head = replace_term_vars fresh_names head in
  let fresh_body = List.map (replace_term_vars fresh_names) body in
  (fresh_names, fresh_head, fresh_body)

(* let freshen_nameless_poly_clause ?(support=[]) ~tysub ~ts clause =
 *   let (tids, head, body) = clause in
 *   let tids' = List.map 
 *     (fun (id,ty) -> (id, apply_sub_ty tysub ty)) tids in
 *   let head' = inst_term_ty tysub head in
 *   let body' = List.map (inst_term_ty tysub) body in
 *   freshen_nameless_clause ~support ~ts (tids',head',body') *)

let freshen_nameless_def ?(support=[]) ~ts head body =
  let tids = capital_tids [head] in
  let fresh_names = fresh_nameless_alist ~support ~tag:Logic ~ts tids in
  let fresh_head = replace_term_vars fresh_names head in
  let fresh_body = replace_metaterm_vars fresh_names body in
  (fresh_head, fresh_body)

let freshen_nameless_bindings ~support ~ts bindings term =
  let alist = fresh_nameless_alist ~support ~tag:Logic ~ts bindings in
  replace_metaterm_vars alist term

let existentially_close ~used quant_vars body =
  let bindings : (id * term) list ref = ref [] in
  let emit x xv = bindings := (x, xv) :: !bindings in
  let rec renumber_one stem cur v =
    let candidate = stem ^ string_of_int cur in
    if List.mem_assoc candidate used then
      renumber_one stem (cur + 1) v
    else begin
      emit v.name (Term.var Constant candidate 0 v.ty) ;
      cur
    end
  in
  List.iter begin fun (x, nvs) ->
    List.fold_left (renumber_one x) 1 nvs |> ignore
  end quant_vars ;
  match List.rev !bindings with
  | [] -> body
  | bindings ->
      let body = replace_metaterm_vars bindings body in
      let bindings =
        List.map (fun (_, xv) -> (term_to_name xv, tc [] xv))
          bindings in
      Binding(Metaterm.Exists, bindings, body)


(* Object level cut *)

(* obj1 = L2, A |- C
   obj2 = L1 |- A
   result = L2, L1 |- C *)
let object_cut obj1 obj2 =
  if obj1.mode <> Async || obj2.mode <> Async then
      failwith "Cannot use cut on sync objects" ;
  if Context.mem obj2.right obj1.context then
    let context = obj1.context |>
                  Context.remove obj2.right |>
                  Context.union obj2.context |>
                  Context.normalize
    in
    if Context.wellformed context then
      Obj({obj1 with context}, Irrelevant)
    else
      failwith "Cannot merge contexts"
  else
    failwith "Needless use of cut"

let object_cut_from obj1 obj2 term =
  if obj1.mode <> Async || obj2.mode <> Async then
      failwith "Cannot use the cut command on backchaining sequents" ;
  let cuttable tobj cut_obj =
    eq tobj.right cut_obj.right
    && Context.subcontext tobj.context cut_obj.context
  in
  let get_cut_ctx tobj cut_obj =
    List.filter_map begin
      fun t -> if Context.mem t tobj.context then None else Some t
    end cut_obj.context
  in
  if not (Context.mem term obj1.context) then
    failwith "Needless use of cut" ;
  let tobj = normalize_obj {context = Context.empty ; right = term ; mode = Async} in
  if List.length tobj > 1 then
    failwith "Cannot cut conjunctive formulas" ;
  let tobj = List.hd tobj in
  let norms = obj_support tobj in
  let nids, ntys = List.split (nominal_tids norms) in
  let cut_objs =
    List.permute (List.length norms) (obj_support obj2) |>
    List.find_all (fun permuted -> ntys = List.map (tc []) permuted) |>
    List.filter_map begin fun permuted ->
      let tobj =
        replace_metaterm_vars
          (List.combine nids permuted)
          (Obj(tobj, Irrelevant)) in
      match tobj with
      | Obj (tobj, _) ->
          if cuttable tobj obj2 then
            let ctx2 = get_cut_ctx tobj obj2 in
            let ctx = obj1.context |>
                      Context.remove term |>
                      Context.union ctx2 |>
                      Context.normalize in
            if Context.wellformed ctx
            then Some (Obj ({obj1 with context = ctx}, Irrelevant))
            else None
          else None
      | _ -> assert false
    end in
  match cut_objs with
  | [] -> failwith "Cannot merge contexts"
  | (obj::_) -> obj


(* Search cut *)

let search_cut ~search_goal obj =
  if obj.mode <> Async then
      failwith "Cannot use the cut command on backchaining sequents" ;
  (* Process the context from head to tail looking for goals to remove *)
  let rec aux left right =
    match right with
    | d::ds ->
        if search_goal (Obj ({mode = Async ; context = left @ ds ; right = d}, Irrelevant)) then
          aux left ds
        else
          aux (d::left) ds
    | [] -> left
  in
  {obj with context = aux [] (List.rev obj.context)}

(* Object level instantiation *)

(* inst t1 with n = t2 *)
let object_inst t1 n t2 =
  if List.mem n (List.map term_to_name (metaterm_support t1)) then
    map_on_objs (fun obj -> [map_obj (replace_term_vars ~tag:Nominal [(n, t2)]) obj]) t1
  else
    failwithf "Did not find %s" n

(* Case analysis *)

type case = {
  bind_state : bind_state ;
  new_vars : (id * term) list ;
  new_hyps : metaterm list ;
}

type stateless_case = {
  stateless_new_vars : (id * term) list ;
  stateless_new_hyps : metaterm list ;
}

let empty_case = { stateless_new_vars = [] ; stateless_new_hyps = [] }

let stateless_case_to_case case =
  { bind_state = get_bind_state () ;
    new_vars = case.stateless_new_vars ;
    new_hyps = case.stateless_new_hyps }

let cpairs_to_eqs cpairs = List.map (fun (x, y) -> Eq(x, y)) cpairs

(* This handles asynchrony on the left *)
let rec recursive_metaterm_case ~used ~sr term =
  match normalize term with
  | True -> Some empty_case
  | False -> None
  | Eq(a, b) ->
      begin match try_left_unify_cpairs ~used a b with
      | Some cpairs ->
          Some {
            (* Names created perhaps by unification *)
            stateless_new_vars = term_vars_alist Eigen [a;b] ;
            stateless_new_hyps = cpairs_to_eqs cpairs
          }
      | None -> None
      end
  | And(left, right) ->
      begin match recursive_metaterm_case ~used ~sr left with
      | None -> None
      | Some {stateless_new_vars = vars_left ;
              stateless_new_hyps = hyps_left } ->
          match recursive_metaterm_case ~used:(vars_left @ used) ~sr right with
          | None -> None
          | Some {stateless_new_vars = vars_right ;
                  stateless_new_hyps = hyps_right } ->
              Some { stateless_new_vars = vars_left @ vars_right ;
                     stateless_new_hyps = hyps_left @ hyps_right }
      end
  | Binding(Metaterm.Exists, tids, body) ->
      let support = metaterm_support term in
      let (alist, vars) = fresh_raised_alist ~sr ~tag:Eigen ~used ~support tids in
      let fresh_body = replace_metaterm_vars alist body in
      let new_vars = List.map term_to_pair vars in
      let nested =
        recursive_metaterm_case ~used:(new_vars @ used) ~sr fresh_body
      in
      begin match nested with
      | None -> None
      | Some { stateless_new_vars = nested_vars ;
               stateless_new_hyps = nested_hyps } ->
          Some { stateless_new_vars = new_vars @ nested_vars ;
                 stateless_new_hyps = nested_hyps }
      end
  | Binding(Nabla, ids, body) ->
      let alist = make_nabla_alist ids body in
      let fresh_body = replace_metaterm_vars alist body in
      recursive_metaterm_case ~used ~sr fresh_body
  | _ -> Some {stateless_new_vars = [] ; stateless_new_hyps = [term]}

let spine_view t =
  let tys, t =
    let t = hnorm t in
    match observe t with
    | Lam(tys, t) -> (tys, t)
    | _ -> ([], t)
  in
  let head, args =
    let t = hnorm t in
    match observe t with
    | App(head, args) -> (head, args)
    | _ -> (t, [])
  in
  (tys, head, args)

let rec is_left_flexible t =
  match observe (hnorm t) with
  | Var v -> v.tag = Eigen
  | DB _ -> false
  | Lam(_, b) -> is_left_flexible b
  | App(h, _) -> is_left_flexible h
  | _ -> assert false

let rec is_left_rigid t =
  match observe (hnorm t) with
  | Var v -> v.tag = Constant || v.tag = Nominal
  | DB _ -> true
  | Lam(_, b) -> is_left_rigid b
  | App(h, _) -> is_left_rigid h
  | _ -> assert false

let one_step_huet ~used ~sr a b =
  let flex_rigid flex rigid =
    let ftys, fhead, fargs = spine_view flex in
    let rtys, rhead, rargs = spine_view rigid in
    if List.length ftys > List.length rtys then
      []
    else
      left_flexible_heads ~used ~sr
        (ftys, fhead, fargs)
        (rtys, rhead, rargs) |>
      List.filter_map ~guard:unwind_state begin fun x ->
        let used = (term_vars_alist Eigen [x]) @ used in
        if try_left_unify ~used fhead x then
          match
            recursive_metaterm_case ~used ~sr (Eq(flex, rigid))
          with
          | None -> None
          | Some sc -> Some(stateless_case_to_case sc)
        else None
      end
  in
  if is_left_flexible a && is_left_rigid b then
    flex_rigid a b
  else if is_left_rigid a && is_left_flexible b then
    flex_rigid b a
  else
    [{ bind_state = get_bind_state () ;
       new_vars = [] ;
       new_hyps = [Eq(a, b)] }]

let rec or_to_list term =
  match term with
  | Or(left, right) -> (or_to_list left) @ (or_to_list right)
  | _ -> [term]

let rec and_to_list term =
  match term with
  | And(left, right) -> (and_to_list left) @ (and_to_list right)
  | _ -> [term]

let rec list_to_and terms =
  List.fold_left1 meta_and terms

let predicate_wrapper r names t =
  let rec aux t =
    match t with
    | True | False | Eq _ | Obj _ -> t
    | Pred(p, _) ->
        if Itab.mem (term_head_name p) names then
          Pred(p, reduce_inductive_restriction r)
        else
          t
    | Binding(binding, ids, body) -> Binding(binding, ids, aux body)
    | Or(t1, t2) -> Or(aux t1, aux t2)
    | And(t1, t2) -> And(aux t1, aux t2)
    | Arrow(t1, t2) -> Arrow(t1, aux t2)
  in
  aux t

let lift_all ~used ~sr nominals =
  used |>
  List.iter begin fun (id, term) ->
    if is_free term then
      let v = term_to_var term in
      let rty, rvars = raise_type ~sr nominals v.ty in
      let new_term = var Eigen id v.ts rty in
      bind term (app new_term rvars)
  end

type spec_view =
  | Spec_atom of term
  | Spec_imp of term * term
  | Spec_amp of term * term
  | Spec_pi of id * ty * term

let spec_view t =
  match observe (hnorm t) with
  | App (imp, [a; b]) when is_imp imp ->
      Spec_imp (a, b)
  | App (amp, [a; b]) when is_amp amp ->
      Spec_amp (a, b)
  | App (pi, [abs]) when is_pi pi -> begin
      match observe (hnorm abs) with
      | Lam ([x, ty], t) -> Spec_pi (x, ty, t)
      | _ -> bugf "Cannot view pi body: %s" (term_to_string abs)
    end
  | t -> Spec_atom t

let case ~used ~sr ~clauses ~mutual ~defs ~global_support term =
  let support = metaterm_support term in
  let def_case ~wrapper term =
    let make_case ~support ~used (head, body) term =
      let fresh_used, head, body =
        freshen_def ~sr ~support ~used head body
      in
      match try_left_unify_cpairs ~used:(fresh_used @ used) head term with
      | Some cpairs ->
          let used_head = term_vars_alist Eigen [head; term] in
          let used_body = metaterm_vars_alist Eigen body in
          let used = List.unique (used_head @ used_body @ used) in
          begin match recursive_metaterm_case ~used ~sr body with
          | None -> []
          | Some case ->
              [{ bind_state = get_bind_state () ;
                 new_vars = case.stateless_new_vars @ used ;
                 new_hyps =
                   cpairs_to_eqs cpairs @
                   List.map wrapper case.stateless_new_hyps }]
          end
      | None -> []
    in
    defs |>
    List.flatten_map ~guard:unwind_state begin function
    | {head = Pred(head, _) ; body} ->
        make_case ~support ~used (head, body) term
    | {head = Binding(Nabla, tids, Pred(head, _)) ; body} ->
        List.range 0 (List.length tids) |>
        List.rev |>
        List.flatten_map begin fun n ->
          (* n is the number of nablas to be raised *)
          List.choose n tids |>
          List.flatten_map ~guard:unwind_state begin fun raised ->
            let (rids, rtys) = List.split raised in
            let nominals =
              (* Want freshness with respect to global support *)
              fresh_nominals rtys (pred (app head global_support))
            in
            let () = lift_all ~used ~sr nominals in
            let head = replace_term_vars (List.combine rids nominals) head in
            let (pids, ptys) = List.split (List.minus tids raised) in
            List.permute (List.length pids) support |>
            List.find_all
              (fun permuted -> ptys = List.map (tc []) permuted) |>
            List.flatten_map ~guard:unwind_state begin fun permuted ->
              let support = List.minus support permuted in
              let head =
                replace_term_vars (List.combine pids permuted) head
              in
              make_case ~support ~used (head, body) term
            end
          end
        end
    | {head ; body} ->
        bugf "Bad head in definitional clause:\n%s := %s"
          (metaterm_to_string head)
          (metaterm_to_string body)
    end
  in

  let focus sync_obj f r =
    if has_eigen_head f then
      failwithf "Head of backchained clause, %s, is a variable.\n\
               \ The case command cannot determine the derivability of this hypothesis"
        (term_to_string f) ;
    let rewrap obj = Obj (obj, reduce_inductive_restriction r) in
    let rewrap_antecedent g = rewrap {sync_obj with mode = Async ; right = g} in
    let rewrap_succedent f = rewrap {sync_obj with mode = Sync f} in
    clausify f |>
    List.filter_map begin fun clause ->
      unwind_state begin fun clause ->
        let fresh_used, fresh_head, fresh_body =
          freshen_clause ~sr ~support ~used clause in
        if has_eigen_head fresh_head then begin
          let new_vars = term_vars_alist Eigen (fresh_head :: sync_obj.right :: fresh_body) in
          let body = List.map rewrap_antecedent fresh_body in
          Some { bind_state = get_bind_state () ;
                 new_vars = new_vars ;
                 new_hyps = rewrap_succedent fresh_head :: body }
        end else begin
            (* Perform the type unification first to determine the
               most general types that instantiate the type variables 
               in the clause *)
            let constrs = left_type_constrs fresh_head sync_obj.right in
            let tysub = Unifyty.solve_constraints constrs in
            match tysub with
            (* type unification fails *)
            | None -> None  
            (* type unification succeeds *)
            | Some tysub' -> 
               if is_ground_tysub tysub' then begin
                 let (fresh_used, fresh_head, fresh_body) =
                   instantiate_poly_clause tysub' fresh_used fresh_head fresh_body in
                 match try_left_unify_cpairs fresh_head sync_obj.right
                         ~used:(fresh_used @ used) with
                 | Some cpairs ->
                    let new_vars =
                      term_vars_alist Eigen (fresh_head::sync_obj.right::fresh_body) in
                    let body = List.map rewrap_antecedent fresh_body in
                    Some { bind_state = get_bind_state () ;
                           new_vars = new_vars ;
                           new_hyps = cpairs_to_eqs cpairs @ body }
                 | None -> None
                 end
               else
                 failwith "Cannot fully infer the type of some specification clause"
          end
      end clause
    end
  in

  let clause_case async_obj r =
    clauses |>
    List.map (fun clause -> focus async_obj clause r) |>
    List.concat
  in

  (* create a sync sequent focusing on a formula
     in the context *)
  let create_sync ~used ~sr ~support async_obj r =
    let raise_result =
      fresh_raised_alist ~sr ~tag:Eigen ~used ~support [("F", oty)] in
    let f, fvar =
      match raise_result with
      | ([(_, f)], [fvar]) -> f, fvar
      | _ -> assert false
    in
    let sync_obj = {async_obj with mode = Sync f} in
    let mem = member f (Context.context_to_term sync_obj.context) in
    { bind_state = get_bind_state () ;
      new_vars = [term_to_pair fvar];
      new_hyps = [Obj(sync_obj, reduce_inductive_restriction r) ; mem] }
  in

  let async_case obj r =
    if has_eigen_head obj.right then
        failwithf "Cannot case-analyze an object sequent with a flexible goal.\n\
                 \ The case command does not enumerate object logic formulas." ;
    let clause_cases = clause_case obj r in
    clause_cases @
    (if Context.is_empty obj.context then []
     else [create_sync ~used ~sr ~support obj r])
  in

  match term with
  | Obj (obj, r) -> begin
      match obj.mode with
      | Async -> async_case obj r
      | Sync f -> focus obj f r
    end
  | True -> [stateless_case_to_case empty_case]
  | False -> []
  | Pred(_, CoSmaller _) -> failwith "Cannot case-analyze hypothesis\
                                    \ with coinductive restriction"
  | Pred(p, r) ->
      def_case ~wrapper:(predicate_wrapper r mutual) p
  | Or _ ->
      or_to_list term |>
      List.filter_map ~guard:unwind_state begin fun g ->
        match recursive_metaterm_case ~used ~sr g with
        | None -> None
        | Some c -> Some(stateless_case_to_case c)
      end
  | Eq(a, b) ->
      begin match recursive_metaterm_case ~used ~sr term with
      | None -> []
      | Some sc ->
          match sc.stateless_new_hyps with
          | [Eq(a', b')] when eq a a' && eq b b' ->
              one_step_huet ~used ~sr a b
          | _ -> [stateless_case_to_case sc]
      end
  | And _
  | Binding(Metaterm.Exists, _, _)
  | Binding(Nabla, _, _) ->
      Option.map_default (fun sc -> [stateless_case_to_case sc]) []
        (recursive_metaterm_case ~used ~sr term)
  | _ ->
      failwith "Cannot perform case-analysis on this kind of formula"

(* Induction *)

let single_induction ind_arg ind_num stmt =
  let rec aux ind_arg stmt =
    match stmt with
    | Binding(Forall, bindings, body) ->
        let (ih, goal) = aux ind_arg body in
        (forall bindings ih, forall bindings goal)
    | Binding(Nabla, bindings, body) ->
        let (ih, goal) = aux ind_arg body in
        (nabla bindings ih, nabla bindings goal)
    | Arrow (left, right) when ind_arg = 1 ->
        let ih = Arrow (set_restriction (Smaller ind_num) left, right) in
        let goal = Arrow (set_restriction (Equal ind_num) left, right) in
        (ih, goal)
    | Arrow (left, right) ->
        let (ih, goal) = aux (ind_arg - 1) right in
        (Arrow (left, ih), Arrow (left, goal))
    | _ ->
        if ind_arg < 1 then
          failwith "Not enough implications in induction"
        else
          failwithf "Cannot determine further positions in:\n%s"
            (metaterm_to_string stmt)
  in
  aux ind_arg stmt

let induction ind_args ind_num stmt =
  let ihs, goals =
    List.combine ind_args (and_to_list stmt) |>
    List.map (fun (arg, goal) -> single_induction arg ind_num goal) |>
    List.split
  in
  (ihs, list_to_and goals)

let coinduction res_num stmt =
  let rec aux stmt =
    match stmt with
    | Binding(Forall, bindings, body) ->
        let (ch, goal) = aux body in
        (forall bindings ch, forall bindings goal)
    | Binding(Nabla, bindings, body) ->
        let (ch, goal) = aux body in
        (nabla bindings ch, nabla bindings goal)
    | Arrow(left, right) ->
        let (ch, goal) = aux right in
        (arrow left ch, arrow left goal)
    | Pred(p, Smaller _) | Pred(p, Equal _) ->
        failwith "Cannot coinduct on inductively restricted goal"
    | Pred(p, _) ->
        let ch = Pred(p, CoSmaller res_num) in
        let goal = Pred(p, CoEqual res_num) in
        (ch, goal)
    | _ ->
        failwithf
          "Cannot perform coinduction on this kind of argument:\n\t%s"
          (metaterm_to_string stmt)
  in
  aux stmt

(* Unfold the current goal *)

let has_restriction test t =
  let rec aux t =
    match t with
    | True | False | Eq _ -> false
    | Obj(_, r) -> test r
    | Arrow(a, b) | Or(a, b) | And(a, b) -> aux a || aux b
    | Binding(_, _, body) -> aux body
    | Pred(_, r) -> test r
  in
  aux t

let has_inductive_restriction t =
  has_restriction (function | Smaller _ | Equal _ -> true | _ -> false) t

let has_coinductive_restriction t =
  has_restriction (function | CoSmaller _ | CoEqual _ -> true | _ -> false) t

let coinductive_wrapper r names t =
  let rec aux t =
    match t with
    | True | False | Eq _ | Obj _ -> t
    | Pred(p, _) ->
        if Itab.mem (term_head_name p) names then
          Pred(p, reduce_coinductive_restriction r)
        else t
    | Binding(binding, ids, body) -> Binding(binding, ids, aux body)
    | Or(t1, t2) -> Or(aux t1, aux t2)
    | And(t1, t2) -> And(aux t1, aux t2)
    | Arrow(t1, t2) -> Arrow(t1, aux t2)
  in
  aux t

let maybe_select sel l = match sel with
  | Abella_types.Select_any -> l
  | Abella_types.Select_num n ->
      if n > List.length l then
        failwithf "Cannot select clause #%d; there are only %d clauses" n
          (List.length l) ;
      [List.nth l (n - 1)]
  | Abella_types.Select_named n ->
      failwith "Cannot select named clauses for inductive predicates"

let unfold_defs ~mdefs clause_sel ~ts goal r =
  let p = term_head_name goal in
  let (mutual, defs) = mdefs in
  let support = term_support goal in
  let wrapper = coinductive_wrapper r mutual in
  let unfold_def tids head body i =
    let (ids, tys) = List.split tids in
    (* Add dummy nominals in case nabla bound variables aren't used *)
    let support =
      (fresh_nominals_by_list tys (List.map term_to_name support)) @
      support
    in
    support |>
    List.permute (List.length tids) |>
    List.find_all (fun nominals -> tys = List.map (tc []) nominals) |>
    List.flatten_map ~guard:unwind_state begin fun nominals ->
      let support = List.minus support nominals in
      let alist = List.combine ids nominals in
      let head = replace_term_vars alist head in
      let head, body = freshen_nameless_def ~support ~ts head body in
      match try_right_unify_cpairs head goal with
      | None -> []
      | Some cpairs ->
          [(get_bind_state (), cpairs, normalize (wrapper body), i)]
    end in
  defs |>
  List.map begin fun {head ; body} ->
    match head with
    | Pred(h, _) -> ([], h, body)
    | Binding(Nabla, tids, Pred(h, _)) -> (tids, h, body)
    | _ -> assert false
  end |>
  List.number |>
  maybe_select clause_sel |>
  List.find_all (fun (i, (_, h, _)) -> term_head_name h = p) |>
  List.flatten_map
    (fun (i, (tids, head, body)) -> unfold_def tids head body i)

let try_unify_cpairs cpairs =
  List.for_all (curry try_right_unify) cpairs

let rec disjoin = function
  | [] -> False
  | [f] -> f
  | f1 :: f2 :: fs -> disjoin (Or(f1, f2) :: fs)

let unfold ~mdefs ~used clause_sel sol_sel goal0 =
  match goal0 with
  | Pred(_, Smaller _) | Pred(_, Equal _) ->
      failwith "Cannot unfold inductively restricted predicate"
  | Pred(goal, r) ->
      (* Find suitable solutions without lingering conflict pairs *)
      let rec select_non_cpairs emit list =
        match list with
        | (state, [], body, _)::rest ->
            set_bind_state state;
            select_non_cpairs (Metaterm.map_terms Term.deep_copy body :: emit) rest
        | _::rest -> select_non_cpairs emit rest
        | [] -> emit
      in
      let unfoldings = unfold_defs ~mdefs clause_sel ~ts:0 goal r in
      begin match select_non_cpairs [] unfoldings with
      | [] -> failwith "No matching clauses"
      | [case1] -> [case1]
      | cases -> begin
          let cases = List.rev cases in
          match sol_sel with
          | Abella_types.Solution_first -> [List.hd cases]
          | Abella_types.Solution_all -> [disjoin cases]
        end
      end
  | Obj ({mode = Async ; _} as goal, sr) -> begin
      match clause_sel with
      | Abella_types.Select_named nm -> begin
          match Typing.lookup_clause nm with
          | Some cl ->
              normalize_obj goal |>
              List.map begin fun goal ->
                let support = metaterm_support goal0 in
                let cl' = cl in
                let cl = clausify cl in
                let _ = if not (List.length cl = 1) then
                failwithf 
                  "Failed to select a clause from '%s' which is normalized to more than one program clauses" (term_to_string cl') in
                let cl = List.hd cl in
                let (vars, head, body) = freshen_nameless_clause ~support ~ts:0 cl in
                (* Perform the type unification first to determine the
                   most general types that instantiate the type variables 
                   in the clause *)
                let constrs = right_type_constrs head goal.right in
                let tysub = Unifyty.solve_constraints_silent constrs in
                match tysub with
                (* type unification succeeds *)
                | Some tysub' when is_ground_tysub tysub' -> begin
                    let (vars, head, body) =
                      instantiate_poly_clause tysub' vars head body in
                    match try_right_unify_cpairs head goal.right with
                    | None ->
                       failwithf "Head of program clause named %S not\
                                  \ unifiable with goal"
                         nm
                    | Some cpairs ->
                       if try_unify_cpairs cpairs then begin
                           let new_vars = List.map (fun (x, xv) -> (x, find_vars Logic [xv])) vars in
                           let quant_vars =
                             List.fold_left
                               (fun vs (x, nvs) -> if nvs = [] then vs else (x, nvs) :: vs)
                               [] new_vars in
                           let body =
                             List.map begin fun g ->
                               let aobj = {goal with right = g} in
                               map_on_objs normalize_obj (Obj (aobj, sr))
                               end body in
                           if quant_vars = [] then body
                           else [existentially_close ~used quant_vars (conjoin body)]
                         end else
                         failwithf "Unsolvable unification of head\
                                    \ of program clause named %S with goal"
                           nm
                  end
                | _ -> 
                (* type unification fails *)
                   failwithf "Type variables in the head of program clause %S\
                              \ cannot be fully inferred by unification"
                      nm
                end |>
                List.concat
          | None ->
             failwithf "Program clause named %S not found" nm
        end
      | _ ->
          failwith "Can only unfold named program clauses for object sequents"
    end
  | Obj _ ->
      failwith "Cannot unfold backchaining sequents"
  | _ ->
      failwith "Cannot unfold this kind of goal"

(* Search *)

exception SearchSuccess of Abella_types.witness

let decompose_arrow term =
  let rec aux acc term =
    match term with
    | Arrow(a, b) -> aux (a::acc) b
    | _ -> (List.rev acc, term)
  in
  aux [] term

let alist_to_ids alist =
  List.map term_to_string (List.map snd alist)

let satisfies r1 r2 =
  match r1, r2 with
  | CoSmaller i, CoSmaller j when i = j -> true
  | CoSmaller _, _ -> false

  | Smaller i, Smaller j
  | Smaller i, Equal j
  | Equal i, Equal j when i = j -> true

  | _, Smaller _ -> false
  | _, Equal _ -> false

  | _ -> true


(** Search

    - Depth is decremented only when unfolding clauses and definitions since
    only these can cause infinite search

    - Each aux search returns () on failure and calls (sc w) on success where
    w is a witness. This allows for effective backtracking.
    sc means success continuation.
*)

let search ~depth:n ~hyps ~clauses ~def_unfold ~retype
    ?(witness=WMagic)
    ?(sc=fun w -> raise (SearchSuccess w)) goal =

  let bad_witness () = failwithf "Bad search witness: %s" (witness_to_string witness) in

  let temporary_hyp_name =
    let count = ref 0 in
    fun () ->
      incr count ;
      "h" ^ (string_of_int !count)
  in

  let rec clause_aux n context foci goal r ts ~sc ~witness =
    (* Printf.eprintf "clause_aux: %s\n%!" (witness_to_string witness) ; *)
    let support = term_list_support (goal :: context) in
    let freshen_clause (i, cl) =
      let (_vars, head, body) = freshen_nameless_clause ~support ~ts cl in
      (i, (head, body))
    in
    let p = term_head_name goal in
    let wrap body = List.map (fun t -> {context ; mode = Async ; right = t}) body in
    let filter_by_witness = match witness with
      | WUnfold (p, n, _) ->
          (fun (i, (_, h, _)) -> term_head_name h = p && i = n)
      | WMagic ->
          (fun _ -> true)
      | _ -> bad_witness ()
    in
    foci |>
    (* ignore the elements in the context of type olist *)
    List.find_all (fun cls -> not (tc [] cls = olistty)) |>
    List.map clausify |>
    List.concat |>
    List.find_all (fun (_, h, _) -> term_head_name h = p) |>
    List.number |>
    List.filter filter_by_witness |>
    List.map freshen_clause |>
    List.iter ~guard:unwind_state begin fun (i, (head, body)) ->
      (* Perform the type unification first to determine the
         most general types that instantiate the type variables 
         in the clause *)
      let constrs = right_type_constrs head goal in
      let tysub = Unifyty.solve_constraints_silent constrs in
      match tysub with
      | None -> ()
      | Some tysub' ->
         let (_, head, body) =
           instantiate_poly_clause tysub' [] head body in
         match try_right_unify_cpairs head goal with
         | None -> ()
         | Some cpairs ->
            let sc ws =
              if try_unify_cpairs cpairs then
                sc (WUnfold(p, i, ws)) in
            let witnesses = match witness with
              | WUnfold (_, _, ws) when List.length ws = List.length body -> ws
              | WMagic -> List.map (fun _ -> WMagic) body
              | _ -> bad_witness ()
            in
            let n = match witness with
              | WUnfold _ -> n
              | _ -> n - 1
            in
            async_obj_aux_conj n (wrap body) r ts ~sc ~witnesses
      end

  and async_obj_aux n hyps goal r ts ~sc ~witness =
    (* Printf.eprintf "axync_obj_aux: %s\n%!" (witness_to_string witness) ; *)
    normalize_obj goal |>
    List.iter begin fun goal ->
      (* Check hyps for derivability *)
      let () =
        hyps |>
        List.find_all (fun (id, h) -> is_async_obj h) |>
        List.find_all (fun (id, h) -> satisfies (term_to_restriction h) r) |>
        List.map (fun (id, h) -> (id, term_to_async_obj h)) |>
        List.iter ~guard:unwind_state begin fun (id, obj) ->
          if derivable goal obj then sc (WHyp id)
        end in
      match r with
      | Smaller _ | Equal _ -> ()
      | _ ->
          (* Backchain *)
          if n > 0 then clause_aux n goal.context (goal.context @ clauses) goal.right r ts ~sc ~witness ;
          (* Also backchain the goal G in '{.. L ..|- G}' on clauses F
             occurring in hypotheses of the form 'member F L' *)
          let ctxs = List.find_all (fun cls -> tc [] cls = olistty) goal.context in
          let get_member_foci hyp =
            if is_member hyp then
              let e, ctx = extract_member hyp in
              if Context.mem ctx ctxs then Some e else None
            else
              None
          in
          let ctx_foci = List.filter_map get_member_foci
              (List.map (fun (id, h) -> h) hyps) in
          let focus_goals = List.map (fun f -> {goal with mode = Sync f}) ctx_foci in
          List.iter (fun fg -> sync_obj_aux n hyps fg r ts ~sc ~witness) focus_goals
    end

  and sync_obj_aux n hyps goal r ts ~sc ~witness =
    (* Printf.eprintf "sync_obj_aux: %s\n%!" (witness_to_string witness) ; *)
    normalize_obj goal |>
    List.iter begin fun goal ->
      let focus = match goal.mode with
        | Sync focus -> focus
        | _ -> bugf "search/sync_obj_aux: not a sync object"
      in
      let filter_by_witness =
        match witness with
        | WMagic -> (fun _ -> true)
        | WHyp wid -> (fun (id, _) -> id = wid)
        | _ -> (fun _ -> false)
      in
      (* Check hyps for derivability *)
      let () =
        hyps |>
        List.filter filter_by_witness |>
        List.find_all (fun (id, h) -> is_sync_obj h) |>
        List.find_all (fun (id, h) -> satisfies (term_to_restriction h) r) |>
        List.map (fun (id, h) -> (id, term_to_sync_obj h)) |>
        List.iter ~guard:unwind_state begin fun (id, obj) ->
          if derivable goal obj then sc (WHyp id)
        end in
      match r with
      | Smaller _ | Equal _ -> ()
      | _ ->
          (* let ctx, focus, term = Sync.get goal in *)
          if n > 0 then begin
            match witness with
            | WMagic | WUnfold _ -> clause_aux n goal.context [focus] goal.right r ts ~sc ~witness
            | _ -> bad_witness ()
          end
    end

  and async_obj_aux_conj n goals r ts ~sc ~witnesses =
    match goals with
    | [] -> sc []
    | g::gs -> begin
        match witnesses with
        | [] -> bad_witness ()  (* [TODO] this check is a bit redundant *)
        | w :: ws ->
            async_obj_aux n hyps g r ts
                 ~witness:w
                 ~sc:(fun w -> async_obj_aux_conj n gs r ts ~sc:(fun ws -> sc (w::ws)) ~witnesses:ws)
      end

  and metaterm_aux n hyps goal ts ~sc ~witness =
    (* Printf.eprintf "metaterm_aux: %s\n%!  -- %s\n%!" (witness_to_string witness) (metaterm_to_string goal) ; *)
    let goal = normalize goal in
    let () =
      hyps |>
      List.iter ~guard:unwind_state begin fun (id, hyp) ->
        let wmatch = match witness with
          | WMagic -> true
          | WHyp h when h = id -> true
          | _ -> false
        in
        if wmatch then
        let pmatch = match hyp, goal with
          | Pred(_, rh), Pred(_, rg)
          | Obj(_, rh), Obj(_, rg) -> satisfies rh rg
          | _ -> true
        in
        if pmatch then
          all_meta_right_permute_unify ~sc:(fun () -> sc (WHyp id)) goal hyp
      end in
    match goal with
    | True -> begin
        match witness with
        | WMagic | WTrue -> sc WTrue
        | _ -> bad_witness ()
      end
    | False -> ()
    | Eq(left, right) -> begin
        match witness with
        | WMagic | WReflexive ->
            unwind_state
              (fun () -> if try_right_unify left right then sc WReflexive)
              ()
        | _ -> bad_witness ()
      end
    | Or(left, right) -> begin
        match witness with
        | WMagic ->
            metaterm_aux n hyps left ts ~sc:(fun w -> sc (WLeft w)) ~witness ;
            metaterm_aux n hyps right ts ~sc:(fun w -> sc (WRight w)) ~witness
        | WLeft w ->
            metaterm_aux n hyps left ts ~sc:(fun w -> sc (WLeft w)) ~witness:w
        | WRight w ->
            metaterm_aux n hyps right ts ~sc:(fun w -> sc (WRight w)) ~witness:w
        | _ -> bad_witness ()
      end
    | And(left, right) -> begin
        match witness with
        | WMagic ->
            metaterm_aux n hyps left ts ~witness
              ~sc:(fun w1 -> metaterm_aux n hyps right ts ~witness
                      ~sc:(fun w2 -> sc (WSplit(w1, w2))))
        | WSplit (w1, w2) ->
            metaterm_aux n hyps left ts ~witness:w1
              ~sc:(fun w1 -> metaterm_aux n hyps right ts ~witness:w2
                      ~sc:(fun w2 -> sc (WSplit(w1, w2))))
        | _ -> bad_witness ()
      end
    | Arrow _ ->
        let (args, body) = decompose_arrow goal in
        let hns, w = match witness with
          | WIntros (hns, w) -> (hns, w)
          | WMagic -> (List.map (fun _ -> temporary_hyp_name ()) args, WMagic)
          | _ -> bad_witness ()
        in
        let args = List.combine hns args in
        metaterm_aux n (args @ hyps) body ts ~witness:w
          ~sc:(fun w -> sc (WIntros(List.map fst args, w)))
    | Binding(Metaterm.Exists, tids, body) ->
        let global_support =
          List.unique
            ((List.flatten_map (fun (_, h) -> metaterm_support h) hyps) @
             (metaterm_support goal))
        in
        let (alist, w) = match witness with
          | WExists (alist, w) ->
              let alist = List.map begin fun (x, t) ->
                  (x, retype (Typing.forget_term t))
                end alist in
              (alist, w)
          | WMagic ->
              (fresh_nameless_alist
                 ~support:global_support ~tag:Logic ~ts tids, WMagic)
          | _ -> bad_witness ()
        in
        let body = replace_metaterm_vars alist body in
        metaterm_aux n hyps body ts ~sc:(fun w -> sc (WExists(alist, w))) ~witness:w
    | Binding(Nabla, tids, body) ->
        let (alist, w) = match witness with
          | WIntros (ids, w) ->
              let alist = List.map2 begin fun id (x, ty) ->
                  (x, nominal_var id ty)
                end ids tids in
              (alist, w)
          | WMagic -> (make_nabla_alist tids body, WMagic)
          | _ -> bad_witness ()
        in
        let body = replace_metaterm_vars alist body in
        metaterm_aux n hyps body ts
          ~sc:(fun w -> sc (WIntros(alist_to_ids alist, w)))
          ~witness:w
    | Binding(Forall, tids, body) ->
        let ts = ts + 1 in
        let (alist, w) = match witness with
          | WForall (ids, w) ->
              let alist = List.map2 begin fun id (x, ty) ->
                  (x, var Eigen id ts ty)
                end ids tids in
              (alist, w)
          | WMagic ->
              (fresh_nameless_alist ~support:[] ~tag:Eigen ~ts tids, WMagic)
          | _ -> bad_witness ()
        in
        let body = replace_metaterm_vars alist body in
        metaterm_aux n hyps body ts
          ~witness:w
          ~sc:(fun w -> sc (WForall(alist_to_ids alist, w)))
    | Obj (obj, r) -> begin
        match obj.mode with
        | Async -> async_obj_aux n hyps obj r ts ~sc ~witness
        | Sync _ -> sync_obj_aux n hyps obj r ts ~sc ~witness
      end
    | Pred(_, Smaller _) | Pred(_, Equal _) -> ()
    | Pred(p, r)  -> if n > 0 then def_aux n hyps p r ts ~sc ~witness

  and def_aux n hyps goal r ts ~sc ~witness =
    (* Printf.eprintf "def_aux: %s\n%!" (witness_to_string witness) ; *)
    let p = term_head_name goal in
    try begin
      let mdefs = def_unfold (Pred (goal, r)) in
      let (csel, witness, subn) = match witness with
        | WMagic -> (Abella_types.Select_any, WMagic, n - 1)
        | WUnfold (wp, wn, [w]) when wp = p -> (Abella_types.Select_num wn, w, n)
        | _ -> bad_witness ()
      in
      let doit () =
        unfold_defs ~mdefs csel ~ts goal r |>
        List.iter begin fun (state, cpairs, body, i) ->
          set_bind_state state ;
          metaterm_aux subn hyps body ts
            ~witness
            ~sc:(fun w -> if try_unify_cpairs cpairs then
                    sc (WUnfold(p, i, [w])))
        end in
      unwind_state doit ()
    end with Failure _ -> ()

  in
  try
    metaterm_aux n hyps goal 0 ~sc ~witness ;
    None
  with SearchSuccess(w) -> Some w

(* Apply one statement to a list of other statements *)

let check_restrictions formal actual =
  if (List.length formal <> List.length actual) then
    failwithf "%s arguments to apply\n(Expected %d but got %d)" begin
      let diff = compare (List.length formal) (List.length actual) in
      if diff > 0 then "Not enough" else "Too many"
    end (List.length formal) (List.length actual) ;
  List.iter2 (fun fr ar -> match fr, ar with
      | Smaller i, Smaller j when i = j -> ()
      | Equal i, Smaller j when i = j -> ()
      | Equal i, Equal j when i = j -> ()
      | Irrelevant, _ -> ()
      | _ -> failwith "Inductive restriction violated")
    formal actual

let rec map_args f t =
  match t with
  | Arrow(left, right) ->
      (f left) :: (map_args f right)
  | _ -> []

let some_term_to_restriction t =
  match t with
  | None -> Irrelevant
  | Some t -> term_to_restriction t

let apply_arrow term args =
  let () = check_restrictions
      (map_args term_to_restriction term)
      (List.map some_term_to_restriction args)
  in
  let context_pairs = ref [] in
  let obligations = ref [] in
  let argno = ref 0 in
  let result =
    List.fold_left begin
      fun term arg ->
         incr argno ;
         let doit () =
           match term, arg with
           | Arrow (Obj (left, _), right), Some (Obj (arg, _)) ->
               (* [HACK] this case should be part of meta_right_unify *)
               context_pairs := (left.context, arg.context) :: !context_pairs ;
               begin match left.mode, arg.mode with
               | Async, Async -> ()
               | Sync lf, Sync af -> right_unify lf af
               | _ -> failwithf "Object sequent kind mismatch at argument %d" !argno
               end ;
               right_unify left.right arg.right ;
               right
           | Arrow(left, right), Some arg ->
               meta_right_unify left arg ; right
           | Arrow(left, right), None ->
               obligations := left::!obligations ;
               right
           | _ ->
               failwith "Too few implications in application"
         in
         try doit () with
         | Unify.UnifyFailure fl -> raise (Unify.UnifyFailure (Unify.FailTrail (!argno, fl)))
    end term args
  in
  (* [HACK] reconcile does not produce failure trails *)
  Context.reconcile !context_pairs ;
  (normalize result, !obligations)

(* Infer type constraints from application *)
let apply_arrow_type_constrs term args =
  let context_pairs = ref [] in
  (* collect type constraints *)
  let (_,constrs) =
    List.fold_left begin
        fun (term, constrs) arg ->
        match term, arg with
        | Arrow (Obj (left, _), right), Some (Obj (arg, _)) ->
           context_pairs := (left.context, arg.context) :: !context_pairs ;
           (* collect type constraints on focused terms *)
           let mode_constrs = 
             begin match left.mode, arg.mode with
             | Sync lf, Sync af -> (right_type_constrs lf af) @ constrs
             | _ -> []
             end
           in
           let goal_constrs = right_type_constrs left.right arg.right in
           (right, mode_constrs @ goal_constrs @ constrs)
        | Arrow(left, right), Some arg ->
           (right, (meta_right_type_constrs left arg) @ constrs)
        | Arrow(left, right), None ->
           (right, constrs)
        | _ ->
           failwith "Too few implications in application"
    end (term, []) args
  in
  let ctx_constrs = Context.reconcile_constrs !context_pairs in
  constrs @ ctx_constrs

let apply ?(used_nominals=[]) term args =
  let hyp_support = metaterm_support term in
  let support = hyp_support @
                  List.flatten_map (Option.map_default metaterm_support []) args in
  let support = List.unique support in
  (* used_nominals are nominal constants provided by 'withs' for
     (partially) instantiating nabla quantified variables and
     should not be raised over by 'forall' quantified variables *)
  let support = List.minus support used_nominals in
  let process_bindings foralls nablas body =
    match nablas with
    | [] -> (* short circuit *)
        apply_arrow (freshen_nameless_bindings ~support ~ts:0 foralls body) args
    | _ ->
        let n = List.length nablas in
        let (nabla_ids, nabla_tys) = List.split nablas in
        (* Add dummy nominals in case nabla bound variables aren't used *)
        let support =
          (fresh_nominals_by_list nabla_tys
             (List.map term_to_name (support @ used_nominals))) @
          support
        in
        (* The nominal constants for nabla quantified variables should
           be chosen from 'candiate_nominals', which contains dummy
           nominals and nominals that occur in the arguments and do
           not occur in the support of the applying term, so as to
           respect the side condition of the nabla-left rule. *)
        let candidate_nominals = List.minus support hyp_support in
        candidate_nominals |> List.rev |> List.permute n |>
        List.find_all begin fun nominals -> 
          let norm_tys = List.map (tc []) nominals in
          let ty_pairs = List.map2 (fun ty1 ty2 -> (ty1, ty2)) norm_tys nabla_tys in
          List.for_all (fun (ty1, ty2) -> Unifyty.ty_compatible ty1 ty2) ty_pairs
        end |>
        List.find_some begin fun nominals ->
          try_with_state ~fail:None
            (fun () ->
              let support = List.minus support nominals in
              let raised_body =
                freshen_nameless_bindings ~support ~ts:0 foralls body
              in
              let alist = List.combine nabla_ids nominals in
              let permuted_body =
                replace_metaterm_vars alist raised_body
              in
              (* Infer the type of the applied term *)
              let constrs = apply_arrow_type_constrs permuted_body args in
              let tysub = Unifyty.solve_constraints_silent constrs in
              match tysub with
              | Some tysub' when is_ground_tysub tysub' ->
                 let permuted_body = 
                   instantiate_poly_metaterm tysub' permuted_body in
                 Some(apply_arrow permuted_body args)
              | _ ->
               failwith "Cannot fully infer the type of the applied term"
            )
        end |>
        (function
          | Some v -> v
          | None ->
              failwith "Failed to find instantiations for nabla-quantified variables")
  in
  match term with
  | Binding(Forall, foralls, Binding(Nabla, nablas, body)) ->
      process_bindings foralls nablas body
  | Binding(Forall, foralls, body) ->
      process_bindings foralls [] body
  | Binding(Nabla, nablas, body) ->
      process_bindings [] nablas body
  | Arrow _ ->
      apply_arrow term args
  | term when args = [] ->
      (term, [])
  | _ ->
      [ "Structure of applied term must be a substructure of the following." ;
        "forall A1 ... Ai, nabla z1 ... zj, H1 -> ... -> Hk -> C" ] |>
      String.concat "\n" |> failwith

(* let apply ?(used_nominals=[]) term args =
 *   let support =
 *     Some term :: args |>
 *     List.flatten_map (Option.map_default metaterm_support []) |>
 *     List.unique |>
 *     (fun s -> List.minus s used_nominals)
 *   in
 *   let process_bindings foralls nablas body =
 *     match nablas with
 *     | [] -> (\* short circuit *\)
 *         apply_arrow (freshen_nameless_bindings ~support ~ts:0 foralls body) args
 *     | _ ->
 *         let n = List.length nablas in
 *         let (nabla_ids, nabla_tys) = List.split nablas in
 *         (\* Add dummy nominals in case nabla bound variables aren't used *\)
 *         let support =
 *           (fresh_nominals_by_list nabla_tys
 *              (List.map term_to_name (support @ used_nominals))) @
 *           support
 *         in
 *         support |> List.rev |> List.permute n |>
 *         List.find_all begin fun nominals -> 
 *           let norm_tys = List.map (tc []) nominals in
 *           let ty_pairs = List.map2 (fun ty1 ty2 -> (ty1, ty2)) norm_tys nabla_tys in
 *           List.for_all (fun (ty1, ty2) -> Unifyty.ty_compatible ty1 ty2) ty_pairs
 *         end |>
 *         List.find_some begin fun nominals ->
 *           let norm_tys = List.map (tc []) nominals in
 *           let ty_pairs = List.map2 (fun ty1 ty2 -> (ty1, ty2)) norm_tys nabla_tys in
 *           List.iter (fun (ty1,ty2) -> add_ty_constraint ty1 ty2) ty_pairs;
 *           try_with_state ~fail:None
 *             (fun () ->
 *                let support = List.minus support nominals in
 *                let raised_body =
 *                  freshen_nameless_bindings ~support ~ts:0 foralls body
 *                in
 *                let alist = List.combine nabla_ids nominals in
 *                let permuted_body =
 *                  replace_metaterm_vars alist raised_body
 *                in
 *                Some(apply_arrow permuted_body args))
 *         end |>
 *         (function
 *           | Some v -> v
 *           | None ->
 *               failwith "Failed to find instantiations for nabla-quantified variables")
 *   in
 *   match term with
 *   | Binding(Forall, foralls, Binding(Nabla, nablas, body)) ->
 *       process_bindings foralls nablas body
 *   | Binding(Forall, foralls, body) ->
 *       process_bindings foralls [] body
 *   | Binding(Nabla, nablas, body) ->
 *       process_bindings [] nablas body
 *   | Arrow _ ->
 *       apply_arrow term args
 *   | term when args = [] ->
 *       (term, [])
 *   | _ ->
 *       [ "Structure of applied term must be a substructure of the following." ;
 *         "forall A1 ... Ai, nabla z1 ... zj, H1 -> ... -> Hk -> C" ] |>
 *       String.concat "\n" |> failwith *)

let rec ensure_unique_nominals lst =
  if not (List.is_unique lst) || not (List.for_all Term.is_nominal lst) then
    failwith "Invalid instantiation for nabla variable"

let take_from_binders binders withs =
  let withs' =
    List.find_all (fun (x, t) -> List.mem_assoc x binders) withs
  in
  let binders' = List.remove_all
      (fun (x, ty) -> List.mem_assoc x withs) binders
  in
  (binders', withs')

let rec instantiate_withs term withs =
  match term with
  | Binding(Forall, binders, body) ->
      let binders', withs' = take_from_binders binders withs in
      let binders_as_withs = List.map (fun (x, t) -> (x, const x t)) binders' in
      let body, used_nominals =
        instantiate_withs (replace_metaterm_vars (withs' @ binders_as_withs) body) withs
      in
      (normalize (forall binders' body), used_nominals)
  | Binding(Nabla, binders, body) ->
      let binders', withs' = take_from_binders binders withs in
      let binders_as_withs = List.map (fun (x, t) -> (x, const x t)) binders' in
      let nominals = List.map snd withs' in
      let support = metaterm_support body in
      ensure_unique_nominals nominals ;
      begin try
        let (xfr, xto) = List.find (fun (xfr, xto) -> List.mem xto support) withs' in
        failwithf "Invalid instantiation %s = %s\n\
                 \ %s already occurs in the support"
          xfr (term_to_string xto) (term_to_string xto)
      with Not_found -> () end ;
      let body, used_nominals =
        instantiate_withs (replace_metaterm_vars (withs' @ binders_as_withs) body) withs
      in
      (normalize (nabla binders' body), nominals @ used_nominals)
  | _ -> (term, [])

let apply_with term args withs =
  if args = [] && withs = [] then
    (term, [])
  else
  let term, used_nominals = instantiate_withs term withs in
  apply (normalize term) args ~used_nominals

(* Backchain *)

(* Infer type constraints from backchaining *)
let backchain_arrow_type_constrs term goal =
  let obligations, head = decompose_arrow term in
  match head, goal with
  | Obj ({mode = Async ; _} as hobj, _), Obj ({mode = Async ; _} as gobj, _) ->
      let gconstrs = right_type_constrs hobj.right gobj.right in
      let cconstrs = 
        Context.backchain_reconcile_constrs hobj.context gobj.context in
      gconstrs @ cconstrs
  | _, _ -> 
      meta_right_type_constrs head goal

let backchain_arrow term goal =
  let obligations, head = decompose_arrow term in
  let () =
    match term_to_restriction head, term_to_restriction goal with
    | CoSmaller i, CoSmaller j when i = j -> ()
    | CoSmaller _, _ -> failwith "Coinductive restriction violated"
    | _, _ -> ()
  in
  begin match head, goal with
  | Obj ({mode = Async ; _} as hobj, _), Obj ({mode = Async ; _} as gobj, _) ->
      right_unify hobj.right gobj.right ;
      Context.backchain_reconcile hobj.context gobj.context
  | _, _ -> begin
      try meta_right_unify head goal with
      | Unify.UnifyFailure fl -> raise (Unify.UnifyFailure (Unify.FailTrail (1, fl)))
    end
  end ;
  obligations

let backchain ?(used_nominals=[]) term goal =
  let support = List.minus (metaterm_support goal) used_nominals in
  match term with
  | Binding(Forall, bindings, Binding(Nabla, nablas, body)) ->
      let n = List.length nablas in
      let (nabla_ids, nabla_tys) = List.split nablas in
      (* Add dummy nominals in case nabla bound variables aren't used *)
      let support =
        (fresh_nominals_by_list nabla_tys
           (List.map term_to_name (support @ used_nominals))) @
          support
      in
      support |> List.rev |> List.permute n |>
      List.find_all begin fun nominals -> 
        let norm_tys = List.map (tc []) nominals in
        let ty_pairs = List.map2 (fun ty1 ty2 -> (ty1, ty2)) norm_tys nabla_tys in
        List.for_all (fun (ty1, ty2) -> Unifyty.ty_compatible ty1 ty2) ty_pairs
      end |>
      List.find_some begin fun nominals ->
        try_with_state ~fail:None
          (fun () ->
             let support = List.minus support nominals in
             let raised_body =
               freshen_nameless_bindings ~support ~ts:0 bindings body
             in
             let alist = List.combine nabla_ids nominals in
             let permuted_body =
               replace_metaterm_vars alist raised_body
             in
             (* Infer the type of the backchained term *)
             let constrs = backchain_arrow_type_constrs permuted_body goal in
             let tysub = Unifyty.solve_constraints_silent constrs in
             match tysub with
             | Some tysub' when is_ground_tysub tysub' ->
                let permuted_body = 
                  instantiate_poly_metaterm tysub' permuted_body in
                Some(backchain_arrow permuted_body goal)
             | _ ->
                failwith "Cannot fully infer the type of the applied term"
          )
      end |>
      (function
        | Some v -> v
        | None ->
            failwith "Failed to find instantiations for nabla quantified variables")

  | Binding(Forall, bindings, body) ->
      backchain_arrow (freshen_nameless_bindings ~support ~ts:0 bindings body) goal

  | _ -> backchain_arrow term goal

let backchain_with term withs goal =
  let term, used_nominals = instantiate_withs term withs in
  backchain term goal ~used_nominals

(* Permute nominals *)

let permute_nominals perm term =
  match perm with
  | h::t ->
      let perm' = t @ [h] in
      let alist =
        List.map2
          (fun src dest ->
             let v = term_to_var src in
             (v.name, nominal_var (term_to_name dest) v.ty))
          perm perm'
      in
      replace_metaterm_vars alist term
  | _ -> assert false
