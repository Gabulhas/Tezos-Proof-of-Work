(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Nomadic Labs, Inc. <contact@nomadic-labs.com>          *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

module Make(M: Hashtbl.HashedType) = struct

  module Table = Ephemeron.K1.Make(
    struct
      type t = int
      let hash a = a
      let equal = (=)
    end)
  module Ring = Ring.MakeTable(
    struct
      type t = int * M.t
      let hash (i,_) = i
      let equal = (=)
    end)
  type key = M.t

  type 'a t = {
    table : 'a Table.t ;
    ring : Ring.t ;
  }

  let create n = { table = Table.create n ; ring = Ring.create n }

  let add { ring ; table } k v =
    let i = M.hash k in
    Ring.add ring (i,k) ;
    Table.replace table i v

  let add_and_return_erased { ring ; table } k v =
    let i = M.hash k in
    let erased =
      Option.map ~f:snd (Ring.add_and_return_erased ring (i, k)) in
    Table.replace table i v ;
    erased

  let find_opt { table ; _ } k =
    let i = M.hash k in
    Table.find_opt table i

  let fold f { table ; ring } acc =
    let elts = Ring.elements ring in
    List.fold_left
      (fun acc (i, k) ->
         match Table.find_opt table i with
         | None -> acc
         | Some elt -> f k elt acc) acc elts

  let iter f {table ; ring } =
    let elts = Ring.elements ring in
    List.iter
      (fun (i, k) ->
         match Table.find_opt table i with
         | None -> ()
         | Some elt -> f k elt ) elts

  let remove t k =
    let i = M.hash k in
    Table.remove t.table i

  let length { table ; _ } = Table.length table

end
