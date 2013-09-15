
(* Pa_solution, a helper library for solving programming contest problems
   -----------------------------------------------------------------------------
   Copyright (C) 2013, Max Mouratov (mmouratov(_)gmail.com)

   License:
     This library is free software; you can redistribute it and/or
     modify it under the terms of the GNU Library General Public
     License version 2.1, as published by the Free Software Foundation.

     This library is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

     See the GNU Library General Public License version 2.1 for more details
     (enclosed in the file LICENSE.txt).
*)


open Camlp4.PreCast
open Syntax


let _loc = Loc.ghost

type spec =
  | Int
  | Int64
  | Float
  | String
  | Line
  | Empty
  | List  of (Ast.expr * spec)          (* list[expr] of spec *)
  | Array of (Ast.expr * spec)          (* array[expr] of spec *)
  | Tuple of spec list                  (* (spec, spec, ...) *)
  | Let   of (Ast.patt * spec * spec)   (* let patt = spec in spec *)
  | Expr  of Ast.expr


(* Code generation utilities
   -------------------------------------------------------------------------- *)

let gensym =
  let id = ref 0 in
  fun () ->
    incr id;
    Printf.sprintf "_%d" !id


(* Reader
   -------------------------------------------------------------------------- *)

let scan format =
  <:expr< Scanf.bscanf in_buf $str:(format)$ (fun _x_ -> _x_) >>

let rec compile_reader (s: spec) : Ast.expr =
  match s with
    | Int    -> scan "%d "
    | Int64  -> scan "%Ld "
    | Float  -> scan "%f "
    | String -> scan "%s "
    | Line   -> scan "%[^\n]\n"

    | Empty ->
        <:expr< try $(compile_reader Line)$ with _ -> "" >>

    | List (size, s) ->
        <:expr< BatList.init $(size)$ (fun _ -> $(compile_reader s)$) >>

    | Array (size, s) ->
        <:expr< BatArray.init $(size)$ (fun _ -> $(compile_reader s)$) >>

    | Tuple specs ->
        let l = specs |> List.map (fun s -> (gensym (), s)) in

        let rec build = function
          | (id, s) :: xs ->
              <:expr< let $lid:(id)$ = $(compile_reader s)$ in $(build xs)$ >>
          | [] ->
              let es = l |> List.map (fun (id, r) -> <:expr< $lid:(id)$ >>) in
              <:expr< $tup:(Ast.exCom_of_list es)$ >>

        in build l

    | Let (patt, s1, s2) ->
        <:expr<
          let $(patt)$ = $(compile_reader s1)$ in
          $(compile_reader s2)$ >>

    | Expr v -> v


(* Writer
   -------------------------------------------------------------------------- *)

let print (v: Ast.expr) format =
  <:expr< Printf.bprintf out_buf $str:(format)$ $(v)$ >>

let rec compile_writer (s: spec) (v: Ast.expr) : Ast.expr =
  match s with
    | Int    -> print v "%d "
    | Int64  -> print v "%Ld "
    | Float  -> print v "%f "
    | String -> print v "%s "
    | Line   -> print v "%s\n"
    | Empty  -> print v "\n"

    | List (size, s) ->
        let id = gensym () in
        let writer = compile_writer s <:expr< $lid:(id)$ >> in
        <:expr< BatList.iter (fun $lid:(id)$ -> $(writer)$) $(v)$ >>

    | Array (size, s) ->
        let id = gensym () in
        let writer = compile_writer s <:expr< $lid:(id)$ >> in
        <:expr< BatArray.iter (fun $lid:(id)$ -> $(writer)$) $(v)$ >>

    | Tuple specs ->
        let l = specs |> List.map (fun r -> (gensym (), r)) in
        let ps = l |> List.map (fun (id, r) -> <:patt< $lid:(id)$ >>) in
        <:expr<
          let $tup:(Ast.paCom_of_list ps)$ = $(v)$ in
          do { $(l |> List.map (fun (id, r) ->
                        compile_writer r <:expr< $lid:(id)$ >>)
                   |> Ast.exSem_of_list)$ }
        >>

    | Let (let_id, s1, s2) ->
        compile_writer s2 v

    | Expr _ -> v


(* The compiler
   -------------------------------------------------------------------------- *)

let compile_solution in_spec out_spec (body: Ast.expr) : Ast.str_item =

  let rec wrap_body = function
    | (patt, spec) :: xs ->
        <:expr< let $(patt)$ = $(compile_reader spec)$ in $(wrap_body xs)$ >>
    | [] ->
        compile_writer out_spec body in

  <:str_item<
    let file = Sys.argv.(1) in
    BatFile.with_file_in ~mode:[`text] (file ^ ".in") (fun in_ch ->
      BatFile.with_file_out ~mode:[`create] (file ^ ".out") (fun out_ch ->
        let in_buf = Scanf.Scanning.from_string (BatIO.read_all in_ch) in
        let out_buf = Buffer.create 1024 in
        do {
          for _i = 1 to (Scanf.bscanf in_buf "%d " identity) do
            Printf.printf "Solving case %d\n%!" _i;
            Printf.bprintf out_buf "%s " (Printf.sprintf "Case #%d:" _i);
            $(wrap_body in_spec)$;
            Printf.bprintf out_buf "\n"
          done;
          BatIO.nwrite out_ch (Buffer.contents out_buf) }))
  >>


(* Syntax extension
   -------------------------------------------------------------------------- *)

EXTEND Gram
  GLOBAL: expr comma_expr str_item;

  let_binding: [
    [ patt = ipatt; ":"; t = typ -> (patt, t) ]
  ];

  typ: [
    [ id = a_LIDENT; "["; idx = comma_expr; "]"; "of"; t = typ ->
      let specs = Ast.list_of_expr idx [] in
      (match id with
        | "list" ->
            List.fold_right (fun idx acc -> List (idx, acc)) specs t
        | "array" ->
            List.fold_right (fun idx acc -> Array (idx, acc)) specs t
        | _ ->
            failwith (Printf.sprintf "Unknown type: %s" id))

    | "tuple"; "("; types = LIST0 typ SEP ","; ")" ->
        Tuple types

    | "let"; binds = LIST1 let_binding SEP ","; "in"; t = typ ->
        List.fold_right (fun (patt, t) a -> Let (patt, t, a)) binds t

    | id = a_LIDENT ->
        (match id with
          | "int"    -> Int
          | "int64"  -> Int64
          | "float"  -> Float
          | "string" -> String
          | "line"   -> Line
          | "empty"  -> Empty
          | id       -> Expr <:expr< $lid:(id)$ >>)

    | e = expr -> Expr e ]
  ];

  input: [
    [ "("; patt = ipatt; ":"; typ = typ; ")" ->
        (patt, typ) ]
  ];

  str_item: LEVEL "top" [
    [ "Solution"; inputs = LIST0 input; ":"; output = typ; "="; body = expr ->
        compile_solution inputs output body ]
  ];

END
