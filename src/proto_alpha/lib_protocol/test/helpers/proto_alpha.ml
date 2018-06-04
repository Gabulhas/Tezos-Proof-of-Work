(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

module Name = struct let name = "alpha" end
module Alpha_environment = Tezos_protocol_environment_memory.MakeV1(Name)()

type alpha_error = Alpha_environment.Error_monad.error
type 'a alpha_tzresult = 'a Alpha_environment.Error_monad.tzresult

include Tezos_protocol_alpha.Functor.Make(Alpha_environment)

module M = Alpha_environment.Lift(Main)
