open Term
open Extensions
open Format

type restriction =
  | Smaller of int
  | Equal of int
  | Irrelevant

type obj = { context : Context.t ;
             term : term }

type binder =
  | Forall
  | Nabla
  | Exists
    
type metaterm =
  | Obj of obj * restriction
  | Arrow of metaterm * metaterm
  | Binding of binder * id list * metaterm
  | Or of metaterm * metaterm
  | And of metaterm * metaterm
  | Pred of term * restriction

(* Constructions *)

let context_obj ctx t = { context = ctx ; term = t }
let obj t = { context = Context.empty ; term = t }

let termobj t = Obj(obj t, Irrelevant)
let arrow a b = Arrow(a, b)
let forall ids t = if ids = [] then t else Binding(Forall, ids, t)
let nabla ids t = if ids = [] then t else Binding(Nabla, ids, t)
let exists ids t = if ids = [] then t else Binding(Exists, ids, t)
let meta_or a b = Or(a, b)
let meta_and a b = And(a, b)
let pred p = Pred(p, Irrelevant)

let member e ctx = pred (app (Term.const "member") [e; ctx])
  
(* Manipulations *)

let map_on_objs f t =
  let rec aux t =
    match t with
      | Obj(obj, r) -> Obj(f obj, r)
      | Arrow(a, b) -> Arrow(aux a, aux b)
      | Binding(binder, bindings, body) -> Binding(binder, bindings, aux body)
      | Or(a, b) -> Or(aux a, aux b)
      | And(a, b) -> And(aux a, aux b)
      | Pred _ -> t
  in
    aux t

let map_obj f obj =
  { context = Context.map f obj.context ;
    term = f obj.term }

let map_terms f t =
  let rec aux t =
    match t with
      | Obj(obj, r) -> Obj(map_obj f obj, r)
      | Arrow(a, b) -> Arrow(aux a, aux b)
      | Binding(binder, bindings, body) ->
          Binding(binder, bindings, aux body)
      | Or(a, b) -> Or(aux a, aux b)
      | And(a, b) -> And(aux a, aux b)
      | Pred(p, r) -> Pred(f p, r)
  in
    aux t
    
let is_imp t =
  match observe t with
    | App(t, _) -> eq t (const "=>")
    | _ -> false

let extract_imp t =
  match observe t with
    | App(t, [a; b]) -> (a, b)
    | _ -> failwith "Check is_imp before calling extract_imp"
          
let move_imp_to_context obj =
  let a, b = extract_imp obj.term in
    {context = Context.add a obj.context ; term = b}

let is_pi_abs t =
  match observe t with
    | App(t, [abs]) -> eq t (const "pi") &&
        begin match observe abs with
          | Lam(1, _) -> true
          | _ -> false
        end
    | _ -> false

let extract_pi_abs t =
  match observe t with
    | App(t, [abs]) -> abs
    | _ -> failwith "Check is_pi_abs before calling extract_pi_abs"

let obj_to_member obj =
  member obj.term (Context.context_to_term obj.context)

let rec filter_objs ts =
  match ts with
    | [] -> []
    | Obj(obj, _)::rest -> obj::(filter_objs rest)
    | _::rest -> filter_objs rest

let rec filter_preds ts =
  match ts with
    | [] -> []
    | Pred(p, _)::rest -> p::(filter_preds rest)
    | _::rest -> filter_preds rest

let term_to_obj t =
  match t with
    | Obj(obj, _) -> obj
    | _ -> failwith "term_to_obj called on non-object"

let term_to_restriction t =
  match t with
    | Obj(_, r) -> r
    | Pred(_, r) -> r
    | _ -> Irrelevant
        
let apply_restriction r t =
  match t with
    | Obj(obj, _) -> Obj(obj, r)
    | Pred(p, _) -> Pred(p, r)
    | _ -> failwith "Attempting to apply restriction to non-object"

let reduce_restriction r =
  match r with
    | Irrelevant -> Irrelevant
    | Equal i -> Smaller i
    | Smaller i -> Smaller i
        
let add_to_context elt obj =
  {obj with context = Context.add elt obj.context}

let add_context ctx obj =
  {obj with context = Context.union ctx obj.context}

(* Variable Renaming *)

let fresh_alist ?(support=[]) ~used ~tag ids =
  let used = ref used in
    List.map (fun x ->
                let (fresh, curr_used) = fresh_wrt tag x !used in
                  used := curr_used ;
                  (x, app fresh support))
      ids

let raise_alist ~support alist =
  List.map (fun (id, t) -> (id, app t support)) alist

let replace_term_vars ?tag alist t =
  let rec aux t =
    match observe t with
      | Var v when List.mem_assoc v.name alist &&
          (tag = None || tag = Some v.tag)
          ->
          List.assoc v.name alist
      | Var _
      | DB _ -> t
      | Lam(i, t) -> lambda i (aux t)
      | App(t, ts) -> app (aux t) (List.map aux ts)
      | Susp _ -> failwith "Susp found during replace_term_vars"
      | Ptr _ -> assert false
  in
    aux (deep_norm t)

let rec replace_metaterm_vars alist t =
  let term_aux t = replace_term_vars alist t in
  let aux t = replace_metaterm_vars alist t in
    match t with
      | Obj(obj, r) -> Obj(map_obj term_aux obj, r)
      | Arrow(a, b) -> Arrow(aux a, aux b)
      | Binding(binder, bindings, body) ->
          let alist' = List.remove_assocs bindings alist in
          let bindings', body' = freshen_alist_bindings bindings alist' body in
            Binding(binder, bindings', replace_metaterm_vars alist' body')
      | Or(a, b) -> Or(aux a, aux b)
      | And(a, b) -> And(aux a, aux b)
      | Pred(p, r) -> Pred(term_aux p, r)

and freshen_alist_bindings bindings alist body =
  let used = get_used (List.map snd alist) in
  let bindings_alist = fresh_alist ~tag:Constant ~used bindings in
  let bindings' =
    List.map (fun v -> v.name)
      (List.map term_to_var (List.map snd bindings_alist))
  in
    (bindings', replace_metaterm_vars bindings_alist body)

let rec collect_terms t =
  match t with
    | Obj(obj, _) -> (Context.context_to_list obj.context) @ [obj.term]
    | Arrow(a, b) -> (collect_terms a) @ (collect_terms b)
    | Binding(_, _, body) -> collect_terms body
    | Or(a, b) -> (collect_terms a) @ (collect_terms b)
    | And(a, b) -> (collect_terms a) @ (collect_terms b)
    | Pred(p, _) -> [p]

let map_term_list f t = List.map f (collect_terms t)

let term_support t = find_var_refs Nominal [t]

let obj_support obj = find_var_refs Nominal (obj.term :: obj.context)

let metaterm_support t =
  let rec aux t =
    match t with
      | Obj(obj, _) -> obj_support obj
      | Arrow(t1, t2) -> aux t1 @ aux t2
      | Binding(_, ids, t) -> aux t
      | Or(t1, t2) -> aux t1 @ aux t2
      | And(t1, t2) -> aux t1 @ aux t2
      | Pred(t, _) -> term_support t
  in
    List.unique (aux t)

let get_metaterm_used t =
  t |> collect_terms
    |> find_var_refs Eigen
    |> List.map (fun v -> ((term_to_var v).name, v))

let get_metaterm_used_nominals t =
  t |> metaterm_support
    |> List.map (fun v -> ((term_to_var v).name, v))
  
let fresh_nominal t =
  let used_vars = find_vars Nominal (collect_terms t) in
  let used_names = List.map (fun v -> v.name) used_vars in
  let p = prefix Nominal in
  let n = ref 1 in
    while List.mem (p ^ (string_of_int !n)) used_names do
      incr n
    done ;
    nominal_var (p ^ (string_of_int !n))

let n_var_names terms =
  terms
  |> map_vars_list (fun v -> v.name)
  |> List.find_all (fun str -> Str.string_match (Str.regexp "^n[0-9]+$") str 0)
  |> List.unique

let replace_nominal_vars term =
  let fresh_nominal_names =
    term
    |> collect_terms
    |> n_var_names
    |> fresh_alist ~tag:Term.Nominal ~used:[]
  in
    replace_metaterm_vars fresh_nominal_names term

let replace_pi_abs_with_nominal obj =
  let abs = extract_pi_abs obj.term in
  let nominal = fresh_nominal (Obj(obj, Irrelevant)) in
    {obj with term = deep_norm (app abs [nominal])}
  
let rec normalize_obj obj =
  if is_imp obj.term then
    normalize_obj (move_imp_to_context obj)
  else if is_pi_abs obj.term then
    normalize_obj (replace_pi_abs_with_nominal obj)
  else
    {obj with context = Context.normalize obj.context}

let rec normalize_binders alist t =
  let term_aux t = replace_term_vars ~tag:Constant alist t in
  let rec aux t =
    match t with
      | Obj(obj, r) -> Obj(map_obj term_aux obj, r)
      | Arrow(a, b) -> Arrow(aux a, aux b)
      | Binding(binder, bindings, body) ->
          let alist_used =
            alist
            |> List.map snd
            |> List.map (fun v -> ((term_to_var v).name, v))
          in
          let body_used = get_metaterm_used body in
          let nominal_used = get_metaterm_used_nominals body in
          let used = alist_used @ body_used @ nominal_used in
          let bindings', body' =
            freshen_used_bindings bindings used body
          in
            Binding(binder, bindings', normalize_binders alist body')
      | Or(a, b) -> Or(aux a, aux b)
      | And(a, b) -> And(aux a, aux b)
      | Pred(p, r) -> Pred(term_aux p, r)
  in
    aux t

and freshen_used_bindings bindings used body =
  let bindings_alist = fresh_alist ~tag:Constant ~used bindings in
  let bindings' =
    bindings_alist
    |> List.map snd
    |> List.map term_to_var
    |> List.map (fun v -> v.name)
  in
  let body' = normalize_binders bindings_alist body in
    (bindings', body')
  
let normalize term =
  term
  |> map_on_objs normalize_obj
  |> normalize_binders []

let abstract_eigen t =
  let vars = find_var_refs Eigen [t] in
    List.fold_right abstract_var (List.rev vars) t

(* Pretty printing *)

let restriction_to_string r =
  match r with
    | Smaller i -> String.make i '*'
    | Equal i -> String.make i '@'
    | Irrelevant -> ""

let bindings_to_string ts =
  String.concat " " ts

let priority t =
  match t with
    | Obj _ -> 4
    | Pred _ -> 4
    | And _ -> 3
    | Or _ -> 2
    | Arrow _ -> 1
    | Binding _ -> 0

let obj_to_string obj =
  let context =
    if Context.is_empty obj.context
    then ""
    else (Context.context_to_string obj.context ^ " |- ")
  in
  let term = term_to_string obj.term in
    "{" ^ context ^ term ^ "}"

let binder_to_string b =
  match b with
    | Forall -> "forall"
    | Nabla -> "nabla"
    | Exists -> "exists"
    
let format_metaterm fmt t =
  let rec aux pr_above t =
    let pr_curr = priority t in
      if pr_curr < pr_above then fprintf fmt "(" ;
      begin match t with
        | Obj(obj, r) ->
            fprintf fmt "%s%s" (obj_to_string obj) (restriction_to_string r)
        | Arrow(a, b) ->
            aux (pr_curr + 1) a ;
            fprintf fmt " ->@ " ;
            aux pr_curr b
        | Binding(b, ids, t) ->
            fprintf fmt "%s %s,@ "
              (binder_to_string b) (bindings_to_string ids) ;
            aux pr_curr t
        | Or(a, b) ->
            aux pr_curr a ;
            fprintf fmt " \\/@ " ;
            aux (pr_curr + 1) b ;
        | And(a, b) ->
            aux pr_curr a ;
            fprintf fmt " /\\@ " ;
            aux (pr_curr + 1) b ;
        | Pred(p, r) ->
            if r = Irrelevant then
              fprintf fmt "%s" (term_to_string p)
            else
              fprintf fmt "%s %s" (term_to_string p) (restriction_to_string r)
      end ;
      if pr_curr < pr_above then fprintf fmt ")" ;
  in
    pp_open_box fmt 2 ;
    aux 0 t ;
    pp_close_box fmt ()

let metaterm_to_string t =
  let b = Buffer.create 50 in
  let fmt = formatter_of_buffer b in
    pp_set_margin fmt max_int ;
    format_metaterm fmt t ;
    pp_print_flush fmt () ;
    Buffer.contents b
  
(* Error reporting *)

let invalid_metaterm_arg t =
  invalid_arg (metaterm_to_string t)

(* Unification *)

open Unify
    
let rec meta_right_unify t1 t2 =
  match t1, t2 with
    | Obj(o1, _), Obj(o2, _) when o1.context = o2.context ->
        right_unify o1.term o2.term
    | Pred(t1, _), Pred(t2, _) ->
        right_unify t1 t2
    | And(l1, r1), And(l2, r2)
    | Or(l1, r1), Or(l2, r2)
    | Arrow(l1, r1), Arrow(l2, r2) ->
        meta_right_unify l1 l2 ;
        meta_right_unify r1 r2
    | Binding(b1, ids1, t1), Binding(b2, ids2, t2)
        when b1 = b2 && ids1 = ids2 -> meta_right_unify t1 t2
    | _, _ -> raise (Failure TypesMismatch)
  
let try_meta_right_unify t1 t2 =
  try_with_state
    (fun () ->
       meta_right_unify t1 t2 ;
       true)    
