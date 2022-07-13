(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech  <contact@trili.tech>                       *)
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

(** Testing
    -------
    Component:    Lib_scoru_wasm input
    Invocation:   dune exec  src/lib_scoru_wasm/test/test_scoru_wasm.exe \
                    -- test "$Encodings^"
    Subject:      Input tests for the tezos-scoru-wasm library
*)

open Tztest
open Tezos_webassembly_interpreter
open Tezos_scoru_wasm

let write_input () =
  let open Lwt.Syntax in
  let input = Input_buffer.alloc () in
  let* () =
    Input_buffer.enqueue
      input
      {
        rtype = 1l;
        raw_level = 2l;
        message_counter = Z.of_int 2;
        payload = Bytes.of_string "hello";
      }
  in
  let* () =
    Input_buffer.enqueue
      input
      {
        rtype = 1l;
        raw_level = 2l;
        message_counter = Z.of_int 3;
        payload = Bytes.of_string "hello";
      }
  in
  assert (Input_buffer.num_elements input = Z.of_int 2) ;
  let* () =
    Lwt.try_bind
      (fun () ->
        Input_buffer.enqueue
          input
          {
            rtype = 1l;
            raw_level = 2l;
            message_counter = Z.of_int 2;
            payload = Bytes.of_string "hello";
          })
      (fun _ -> assert false)
      (function
        | Input_buffer.Cannot_store_an_earlier_message -> Lwt.return ()
        | _ -> assert false)
  in
  Lwt.return Result.return_unit

let read_input () =
  let open Lwt.Syntax in
  let lim = Types.(MemoryType {min = 100l; max = Some 1000l}) in
  let memory = Memory.alloc lim in
  let input_buffer = Input_buffer.alloc () in
  let* () =
    Input_buffer.enqueue
      input_buffer
      {
        rtype = 1l;
        raw_level = 2l;
        message_counter = Z.of_int 2;
        payload = Bytes.of_string "hello";
      }
  in
  assert (Input_buffer.num_elements input_buffer = Z.one) ;
  let module_inst =
    ref Tezos_webassembly_interpreter.Instance.empty_module_inst
  in
  let memories =
    Tezos_webassembly_interpreter.Instance.Vector.cons
      memory
      !module_inst.memories
  in
  module_inst := {!module_inst with memories} ;
  let* result =
    Host_funcs.Internal_for_tests.aux_write_input_in_memory
      ~input_buffer
      ~module_inst
      ~rtype_offset:0L
      ~level_offset:4L
      ~id_offset:10L
      ~dst:50L
      ~max_bytes:36000L
  in
  let* memory =
    Tezos_webassembly_interpreter.Instance.Vector.get 0l !module_inst.memories
  in
  assert (Input_buffer.num_elements input_buffer = Z.zero) ;
  assert (result = 5) ;
  let* m = Memory.load_bytes memory 0L 1 in
  assert (m = "\001") ;
  let* m = Memory.load_bytes memory 4L 1 in
  assert (m = "\002") ;
  let* m = Memory.load_bytes memory 10L 1 in
  assert (m = "\002") ;
  let* m = Memory.load_bytes memory 50L 5 in
  assert (m = "hello") ;
  Lwt.return @@ Result.return_unit

let test_host_fun () =
  let open Lwt.Syntax in
  let input = Input_buffer.alloc () in
  let* () =
    Input_buffer.enqueue
      input
      {
        rtype = 1l;
        raw_level = 2l;
        message_counter = Z.of_int 2;
        payload = Bytes.of_string "hello";
      }
  in
  let module_inst = Tezos_webassembly_interpreter.Instance.empty_module_inst in
  let memories =
    Tezos_webassembly_interpreter.Lazy_vector.LwtInt32Vector.cons
      (Memory.alloc (MemoryType Types.{min = 20l; max = Some 3600l}))
      module_inst.memories
  in
  let module_inst = {module_inst with memories} in
  let values =
    Values.
      [
        Num (I64 0L); Num (I64 4L); Num (I64 10L); Num (I64 50L); Num (I64 3600L);
      ]
  in
  let* module_inst, result =
    Eval.invoke ~module_inst ~input Host_funcs.read_input values
  in
  let* memory =
    Tezos_webassembly_interpreter.Lazy_vector.LwtInt32Vector.get
      0l
      module_inst.memories
  in
  assert (Input_buffer.num_elements input = Z.zero) ;
  let* m = Memory.load_bytes memory 0L 1 in
  assert (m = "\001") ;
  let* m = Memory.load_bytes memory 4L 1 in
  assert (m = "\002") ;
  let* m = Memory.load_bytes memory 10L 1 in
  assert (m = "\002") ;
  let* m = Memory.load_bytes memory 50L 5 in
  assert (m = "hello") ;
  assert (result = Values.[Num (I32 5l)]) ;
  Lwt.return @@ Result.return_unit

let tests =
  [
    tztest "Write input" `Quick write_input;
    tztest "Read input" `Quick read_input;
    tztest "Host read input" `Quick test_host_fun;
  ]