module type Single_data_storage = sig
  type t

  type context = t

  (** The type of the value *)
  type value

  (** Tells if the data is already defined *)
  val mem : context -> bool Lwt.t

  (** Retrieve the value from the storage bucket ; returns a
      {!Storage_error} if the key is not set or if the deserialisation
      fails *)
  val get : context -> value tzresult Lwt.t

  (** Retrieves the value from the storage bucket ; returns [None] if
      the data is not initialized, or {!Storage_helpers.Storage_error}
      if the deserialisation fails *)
  val find : context -> value option tzresult Lwt.t

  (** Allocates the storage bucket and initializes it ; returns a
      {!Storage_error Existing_key} if the bucket exists *)
  val init : context -> value -> Raw_context.t tzresult Lwt.t

  (** Updates the content of the bucket ; returns a {!Storage_Error
      Missing_key} if the value does not exists *)
  val update : context -> value -> Raw_context.t tzresult Lwt.t

  (** Allocates the data and initializes it with a value ; just
      updates it if the bucket exists *)
  val add : context -> value -> Raw_context.t Lwt.t

  (** When the value is [Some v], allocates the data and initializes
      it with [v] ; just updates it if the bucket exists. When the
      value is [None], delete the storage bucket when the value ; does
      nothing if the bucket does not exists. *)
  val add_or_remove : context -> value option -> Raw_context.t Lwt.t

  (** Delete the storage bucket ; returns a {!Storage_error
      Missing_key} if the bucket does not exists *)
  val remove_existing : context -> Raw_context.t tzresult Lwt.t

  (** Removes the storage bucket and its contents ; does nothing if
      the bucket does not exists *)
  val remove : context -> Raw_context.t Lwt.t
end
[@@coq_precise_signature]

(** Restricted version of {!Indexed_data_storage} w/o iterators. *)
module type Non_iterable_indexed_data_storage = sig
  type t

  type context = t

  (** An abstract type for keys *)
  type key

  (** The type of values *)
  type value

  (** Tells if a given key is already bound to a storage bucket *)
  val mem : context -> key -> bool Lwt.t

  (** Retrieve a value from the storage bucket at a given key ;
      returns {!Storage_error Missing_key} if the key is not set ;
      returns {!Storage_error Corrupted_data} if the deserialisation
      fails. *)
  val get : context -> key -> value tzresult Lwt.t

  (** Retrieve a value from the storage bucket at a given key ;
      returns [None] if the value is not set ; returns {!Storage_error
      Corrupted_data} if the deserialisation fails. *)
  val find : context -> key -> value option tzresult Lwt.t

  (** Updates the content of a bucket ; returns A {!Storage_Error
      Missing_key} if the value does not exists. *)
  val update : context -> key -> value -> Raw_context.t tzresult Lwt.t

  (** Allocates a storage bucket at the given key and initializes it ;
      returns a {!Storage_error Existing_key} if the bucket exists. *)
  val init : context -> key -> value -> Raw_context.t tzresult Lwt.t

  (** Allocates a storage bucket at the given key and initializes it
      with a value ; just updates it if the bucket exists. *)
  val add : context -> key -> value -> Raw_context.t Lwt.t

  (** When the value is [Some v], allocates the data and initializes
      it with [v] ; just updates it if the bucket exists. When the
      value is [None], delete the storage bucket when the value ; does
      nothing if the bucket does not exists. *)
  val add_or_remove : context -> key -> value option -> Raw_context.t Lwt.t

  (** Delete a storage bucket and its contents ; returns a
      {!Storage_error Missing_key} if the bucket does not exists. *)
  val remove_existing : context -> key -> Raw_context.t tzresult Lwt.t

  (** Removes a storage bucket and its contents ; does nothing if the
      bucket does not exists. *)
  val remove : context -> key -> Raw_context.t Lwt.t
end
[@@coq_precise_signature]


(** The generic signature of indexed data accessors (a set of values
    of the same type indexed by keys of the same form in the
    hierarchical (key x value) database). *)
module type Indexed_data_storage = sig
  include Non_iterable_indexed_data_storage

  (** Empties all the keys and associated data. *)
  val clear : context -> Raw_context.t Lwt.t

  (** Lists all the keys. *)
  val keys : context -> key list Lwt.t

  (** Lists all the keys and associated data. *)
  val bindings : context -> (key * value) list Lwt.t

  (** Iterates over all the keys and associated data. *)
  val fold :
    context ->
    order:[`Sorted | `Undefined] ->
    init:'a ->
    f:(key -> value -> 'a -> 'a Lwt.t) ->
    'a Lwt.t

  (** Iterate over all the keys. *)
  val fold_keys :
    context ->
    order:[`Sorted | `Undefined] ->
    init:'a ->
    f:(key -> 'a -> 'a Lwt.t) ->
    'a Lwt.t
end

module type Indexed_data_snapshotable_storage = sig
  type snapshot

  type key

  include Indexed_data_storage with type key := key

  module Snapshot :
    Indexed_data_storage
      with type key = snapshot * key
       and type value = value
       and type t = t

  val snapshot_exists : context -> snapshot -> bool Lwt.t

  val snapshot : context -> snapshot -> Raw_context.t tzresult Lwt.t

  val fold_snapshot :
    context ->
    snapshot ->
    order:[`Sorted | `Undefined] ->
    init:'a ->
    f:(key -> value -> 'a -> 'a tzresult Lwt.t) ->
    'a tzresult Lwt.t

  val delete_snapshot : context -> snapshot -> Raw_context.t Lwt.t
end

(** The generic signature of a data set accessor (a set of values
    bound to a specific key prefix in the hierarchical (key x value)
    database). *)
module type Data_set_storage = sig
  type t

  type context = t

  (** The type of elements. *)
  type elt

  (** Tells if a elt is a member of the set *)
  val mem : context -> elt -> bool Lwt.t

  (** Adds a elt is a member of the set *)
  val add : context -> elt -> Raw_context.t Lwt.t

  (** Removes a elt of the set ; does nothing if not a member *)
  val remove : context -> elt -> Raw_context.t Lwt.t

  (** Returns the elements of the set, deserialized in a list in no
      particular order. *)
  val elements : context -> elt list Lwt.t

  (** Iterates over the elements of the set. *)
  val fold :
    context ->
    order:[`Sorted | `Undefined] ->
    init:'a ->
    f:(elt -> 'a -> 'a Lwt.t) ->
    'a Lwt.t

  (** Removes all elements in the set *)
  val clear : context -> Raw_context.t Lwt.t
end

module type NAME = sig
  val name : Raw_context.key
end

module type VALUE = sig
  type t

  val encoding : t Data_encoding.t
end

module type REGISTER = sig
  val ghost : bool
end

module type Indexed_raw_context = sig
  type t

  type context = t

  type key

  type 'a ipath

  val clear : context -> Raw_context.t Lwt.t

  val fold_keys :
    context ->
    order:[`Sorted | `Undefined] ->
    init:'a ->
    f:(key -> 'a -> 'a Lwt.t) ->
    'a Lwt.t

  val keys : context -> key list Lwt.t

  val remove : context -> key -> context Lwt.t

  val copy : context -> from:key -> to_:key -> context tzresult Lwt.t

  module Make_set (_ : REGISTER) (_ : NAME) :
    Data_set_storage with type t = t and type elt = key

  module Make_map (_ : NAME) (V : VALUE) :
    Indexed_data_storage with type t = t and type key = key and type value = V.t

  module Raw_context : Raw_context.T with type t = t ipath
end

