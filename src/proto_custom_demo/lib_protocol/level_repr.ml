(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

type t = {level : Raw_level_repr.t; level_position : int32}

include Compare.Make (struct
  type nonrec t = t

  let compare {level = l1;_} {level = l2;_} = Raw_level_repr.compare l1 l2
end)

type level = t

let pp ppf {level; _} = Raw_level_repr.pp ppf level

let pp_full ppf l =
  Format.fprintf
    ppf
    "%a.%ld (cycle %a.%ld)"
    Raw_level_repr.pp
    l.level
    l.level_position

let encoding =
  let open Data_encoding in
  conv
    (fun {level; level_position} -> (level, level_position))
    (fun (level, level_position) -> {level; level_position})
    (obj2
       (req
          "level"
          ~description:
            "The level of the block relative to genesis. This is also the \
             Shell's notion of level"
          Raw_level_repr.encoding)
       (req
          "level_position"
          ~description:
            "The level of the block relative to the block that starts protocol \
             alpha. This is specific to the protocol alpha. Other protocols \
             might or might not include a similar notion."
          int32))

let root_level first_level = {level = first_level; level_position = 0l}

let level_from_raw ~first_level level =
  let raw_level = Raw_level_repr.to_int32 level in
  let first_level = Raw_level_repr.to_int32 first_level in
  let level_position = Compare.Int32.max 0l (Int32.sub raw_level first_level) in
  {level; level_position}

let diff {level = l1; _} {level = l2; _} =
  Int32.sub (Raw_level_repr.to_int32 l1) (Raw_level_repr.to_int32 l2)

type compat_t = {level : Raw_level_repr.t; level_position : int32}

let compat_encoding =
  let open Data_encoding in
  conv
    (fun {level; level_position} -> (level, level_position))
    (fun (level, level_position) -> {level; level_position})
    (obj2
       (req
          "level"
          ~description:
            "The level of the block relative to genesis. This is also the \
             Shell's notion of level"
          Raw_level_repr.encoding)
       (req
          "level_position"
          ~description:
            "The level of the block relative to the block that starts protocol \
             alpha. This is specific to the protocol alpha. Other protocols \
             might or might not include a similar notion."
          int32))

