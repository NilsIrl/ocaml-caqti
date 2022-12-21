(* Copyright (C) 2017--2022  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the LGPL-3.0 Linking Exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * and the LGPL-3.0 Linking Exception along with this library.  If not, see
 * <http://www.gnu.org/licenses/> and <https://spdx.org>, respectively.
 *)

open Caqti_platform
open Printf
module Pg = Postgresql

module Config_keys = Config_keys
module String_map = Config_keys.String_map

let ( |>? ) = Result.bind
let ( %>? ) f g x = match f x with Ok y -> g y | Error _ as r -> r

let pct_encoder =
  Uri.pct_encoder ~query_value:(`Custom (`Query_value, "", "=")) ()

module Int_hashable = struct
  type t = int
  let equal (i : int) (j : int) = i = j
  let hash (i : int) = Hashtbl.hash i
end

module Int_hashtbl = Hashtbl.Make (Int_hashable)

module Q = struct
  open Caqti_request.Infix
  open Caqti_type.Std

  let start = unit -->. unit @:- "BEGIN"
  let commit = unit -->. unit @:- "COMMIT"
  let rollback = unit -->. unit @:- "ROLLBACK"

  let type_oid = string -->? int @:-
    "SELECT oid FROM pg_catalog.pg_type WHERE typname = ?"

  let set_timezone_to_utc = (unit ->. unit) ~oneshot:true
    "SET TimeZone TO 'UTC'"

  let set_statement_timeout t =
    (unit -->. unit) ~oneshot:true @@ fun _ ->
    (* Parameters are not supported for SET. *)
    S[L"SET statement_timeout TO "; L(string_of_int t)]
end

type Caqti_error.msg +=
  | Connect_error_msg of {
      error: Pg.error;
    }
  | Connection_error_msg of {
      error: Pg.error;
      connection_status: Pg.connection_status;
    }
  | Result_error_msg of {
      error_message: string;
      sqlstate: string;
    }

let extract_connect_error error = Connect_error_msg {error}

let extract_communication_error connection error =
  Connection_error_msg {
    error;
    connection_status = connection#status;
  }

let extract_result_error result =
  Result_error_msg {
    error_message = result#error;
    sqlstate = result#error_field Pg.Error_field.SQLSTATE;
  }

let () =
  let pp ppf = function
   | Connect_error_msg {error; _} | Connection_error_msg {error; _} ->
      Format.pp_print_string ppf (Pg.string_of_error error)
   | Result_error_msg {error_message; _} ->
      Format.pp_print_string ppf error_message
   | _ ->
      assert false
  in
  let cause = function
   | Result_error_msg {sqlstate; _} ->
      Postgresql_conv.cause_of_sqlstate sqlstate
   | _ ->
      assert false
  in
  Caqti_error.define_msg ~pp [%extension_constructor Connect_error_msg];
  Caqti_error.define_msg ~pp [%extension_constructor Connection_error_msg];
  Caqti_error.define_msg ~pp ~cause [%extension_constructor Result_error_msg]

let driver_info =
  Caqti_driver_info.create
    ~uri_scheme:"postgresql"
    ~dialect_tag:`Pgsql
    ~parameter_style:(`Indexed (fun i -> "$" ^ string_of_int (succ i)))
    ~can_pool:true
    ~can_concur:true
    ~can_transact:true
    ()

let no_env _ _ = raise Not_found

module Pg_ext = struct
  include Postgresql_conv

  let query_string ~env (db : Pg.connection) templ =
    let buf = Buffer.create 64 in
    let rec loop = function
     | Caqti_query.L s -> Buffer.add_string buf s
     | Caqti_query.Q s ->
        Buffer.add_char buf '\'';
        Buffer.add_string buf (db#escape_string s);
        Buffer.add_char buf '\''
     | Caqti_query.P i -> bprintf buf "$%d" (i + 1)
     | Caqti_query.E _ -> assert false
     | Caqti_query.S frags -> List.iter loop frags
    in
    loop (Caqti_query.expand ~final:true env templ);
    Buffer.contents buf

  let escaped_connvalue s =
    let buf = Buffer.create (String.length s) in
    let aux = function
     | '\\' -> Buffer.add_string buf {|\\|}
     | '\'' -> Buffer.add_string buf {|\'|}
     | ch -> Buffer.add_char buf ch in
    String.iter aux s;
    Buffer.contents buf

  let conninfo_of_config config =
    let uri = Caqti_config_map.find Config_keys.endpoint_uri config in
    let settings = Config_keys.extract_conninfo config in
    let conninfo =
      (match String_map.is_empty settings, uri with
       | true, Some uri when Uri.host uri <> None ->
          Uri.to_string ~pct_encoder uri
       | _ ->
          let add_qp (k, vs) = String_map.add k (String.concat "," vs) in
          settings
            |> Option.fold ~none:Fun.id ~some:(String_map.add "host")
                (Option.bind uri Uri.host)
            |> List_ext.fold add_qp (Option.fold ~none:[] ~some:Uri.query uri)
            |> String_map.bindings
            |> List.map (fun (k, v) -> k ^ "='" ^ escaped_connvalue v ^ "'")
            |> String.concat " ")
    in
    conninfo
end

let bool_oid = Pg.oid_of_ftype Pg.BOOL
let int2_oid = Pg.oid_of_ftype Pg.INT2
let int4_oid = Pg.oid_of_ftype Pg.INT4
let int8_oid = Pg.oid_of_ftype Pg.INT8
let float8_oid = Pg.oid_of_ftype Pg.FLOAT8
let bytea_oid = Pg.oid_of_ftype Pg.BYTEA
let date_oid = Pg.oid_of_ftype Pg.DATE
let timestamp_oid = Pg.oid_of_ftype Pg.TIMESTAMPTZ
let interval_oid = Pg.oid_of_ftype Pg.INTERVAL
let unknown_oid = Pg.oid_of_ftype Pg.UNKNOWN

let init_param_types ~uri ~type_oid_cache =
  let rec oid_of_field_type : type a. a Caqti_type.Field.t -> _ = function
   | Caqti_type.Bool -> Ok bool_oid
   | Caqti_type.Int -> Ok int8_oid
   | Caqti_type.Int16 -> Ok int2_oid
   | Caqti_type.Int32 -> Ok int4_oid
   | Caqti_type.Int64 -> Ok int8_oid
   | Caqti_type.Float -> Ok float8_oid
   | Caqti_type.String -> Ok unknown_oid
   | Caqti_type.Octets -> Ok bytea_oid
   | Caqti_type.Pdate -> Ok date_oid
   | Caqti_type.Ptime -> Ok timestamp_oid
   | Caqti_type.Ptime_span -> Ok interval_oid
   | Caqti_type.Enum name -> Ok (Hashtbl.find type_oid_cache name)
   | field_type ->
      (match Caqti_type.Field.coding driver_info field_type with
       | None ->
          Error (Caqti_error.encode_missing ~uri ~field_type ())
       | Some (Caqti_type.Field.Coding {rep; _}) ->
          oid_of_field_type rep)
  in
  let rec recurse : type a. _ -> _ -> a Caqti_type.t -> _ -> _
      = fun pt bp -> function
   | Caqti_type.Unit -> fun i -> Ok i
   | Caqti_type.Field ft -> fun i ->
      oid_of_field_type ft |>? fun oid ->
      pt.(i) <- oid;
      bp.(i) <- oid = bytea_oid;
      Ok (i + 1)
   | Caqti_type.Option t ->
      recurse pt bp t
   | Caqti_type.Tup2 (t0, t1) ->
      recurse pt bp t0 %>? recurse pt bp t1
   | Caqti_type.Tup3 (t0, t1, t2) ->
      recurse pt bp t0 %>? recurse pt bp t1 %>?
      recurse pt bp t2
   | Caqti_type.Tup4 (t0, t1, t2, t3) ->
      recurse pt bp t0 %>? recurse pt bp t1 %>?
      recurse pt bp t2 %>? recurse pt bp t3
   | Caqti_type.Custom {rep; _} ->
      recurse pt bp rep
   | Caqti_type.Annot (_, t0) ->
      recurse pt bp t0
  in
  fun pt bp t ->
    recurse pt bp t 0 |>? fun np ->
    assert (np = Array.length pt);
    assert (np = Array.length bp);
    Ok ()

module type STRING_ENCODER = sig
  val encode_string : string -> string
  val encode_octets : string -> string
end

module Make_encoder (String_encoder : STRING_ENCODER) = struct
  open String_encoder

  let rec encode_field
      : type a. uri: Uri.t -> a Caqti_type.Field.t -> a -> (string, _) result =
    fun ~uri field_type x ->
    (match field_type with
     | Caqti_type.Bool -> Ok (Pg_ext.pgstring_of_bool x)
     | Caqti_type.Int -> Ok (string_of_int x)
     | Caqti_type.Int16 -> Ok (string_of_int x)
     | Caqti_type.Int32 -> Ok (Int32.to_string x)
     | Caqti_type.Int64 -> Ok (Int64.to_string x)
     | Caqti_type.Float -> Ok (sprintf "%.17g" x)
     | Caqti_type.String -> Ok (encode_string x)
     | Caqti_type.Enum _ -> Ok (encode_string x)
     | Caqti_type.Octets -> Ok (encode_octets x)
     | Caqti_type.Pdate -> Ok (Conv.iso8601_of_pdate x)
     | Caqti_type.Ptime -> Ok (Pg_ext.pgstring_of_pdate x)
     | Caqti_type.Ptime_span -> Ok (Pg_ext.pgstring_of_ptime_span x)
     | _ ->
        (match Caqti_type.Field.coding driver_info field_type with
         | None -> Error (Caqti_error.encode_missing ~uri ~field_type ())
         | Some (Caqti_type.Field.Coding {rep; encode; _}) ->
            (match encode x with
             | Ok y -> encode_field ~uri rep y
             | Error msg ->
                let msg = Caqti_error.Msg msg in
                let typ = Caqti_type.field field_type in
                Error (Caqti_error.encode_rejected ~uri ~typ msg))))

  let encode ~uri params t x =
    let write_value ~uri ft fv i =
      (match encode_field ~uri ft fv with
       | Ok s -> params.(i) <- s; Ok (i + 1)
       | Error _ as r -> r)
    in
    let write_null ~uri:_ _ i = Ok (i + 1) in
    Request_utils.encode_param ~uri {write_value; write_null} t x 0
      |> Result.map (fun n -> assert (n = Array.length params))
end

module Param_encoder = Make_encoder (struct
  let encode_string s = s
  let encode_octets s = s
end)

let rec decode_field
    : type a. uri: Uri.t -> a Caqti_type.Field.t -> string ->
      (a, [> Caqti_error.retrieve]) result =
  fun ~uri field_type s ->
  let wrap_conv_exn f s =
    (try Ok (f s) with
     | _ ->
        let msg = Caqti_error.Msg (sprintf "Invalid value %S." s) in
        let typ = Caqti_type.field field_type in
        Error (Caqti_error.decode_rejected ~uri ~typ msg))
  in
  let wrap_conv_res f s =
    (match f s with
     | Ok _ as r -> r
     | Error msg ->
        let msg = Caqti_error.Msg msg in
        let typ = Caqti_type.field field_type in
        Error (Caqti_error.decode_rejected ~uri ~typ msg))
  in
  (match field_type with
   | Caqti_type.Bool -> wrap_conv_exn Pg_ext.bool_of_pgstring s
   | Caqti_type.Int -> wrap_conv_exn int_of_string s
   | Caqti_type.Int16 -> wrap_conv_exn int_of_string s
   | Caqti_type.Int32 -> wrap_conv_exn Int32.of_string s
   | Caqti_type.Int64 -> wrap_conv_exn Int64.of_string s
   | Caqti_type.Float -> wrap_conv_exn float_of_string s
   | Caqti_type.String -> Ok s
   | Caqti_type.Enum _ -> Ok s
   | Caqti_type.Octets -> Ok (Postgresql.unescape_bytea s)
   | Caqti_type.Pdate -> wrap_conv_res Conv.pdate_of_iso8601 s
   | Caqti_type.Ptime -> wrap_conv_res Conv.ptime_of_rfc3339_utc s
   | Caqti_type.Ptime_span -> wrap_conv_res Pg_ext.ptime_span_of_pgstring s
   | _ ->
      (match Caqti_type.Field.coding driver_info field_type with
       | None -> Error (Caqti_error.decode_missing ~uri ~field_type ())
       | Some (Caqti_type.Field.Coding {rep; decode; _}) ->
          (match decode_field ~uri rep s with
           | Ok y ->
              (match decode y with
               | Ok _ as r -> r
               | Error msg ->
                  let msg = Caqti_error.Msg msg in
                  let typ = Caqti_type.field field_type in
                  Error (Caqti_error.decode_rejected ~uri ~typ msg))
           | Error _ as r -> r)))

let decode_row ~uri row_type =
  let read_value ~uri ft (resp, i, j) =
    (match decode_field ~uri ft (resp#getvalue i j) with
     | Ok y -> Ok (y, (resp, i, j + 1))
     | Error _ as r -> r)
  in
  let skip_null n (resp, i, j) =
    let j' = j + n in
    let rec check k = k = j' || resp#getisnull i k && check (k + 1) in
    if check j then Some (resp, i, j') else None
  in
  let decode = Request_utils.decode_row ~uri {read_value; skip_null} row_type in
  fun (resp, i) ->
    Result.map
      (fun (y, (_, _, j)) -> assert (j = Caqti_type.length row_type); y)
      (decode (resp, i, 0))

type prepared = {
  query: string;
  param_length: int;
  param_types: Pg.oid array;
  binary_params: bool array;
  single_row_mode: bool;
}

module Connect_functor (System : Caqti_platform_unix.System_sig.S) = struct
  open System
  module H = Connection_utils.Make_helpers (System)

  let (>>=?) m mf = m >>= (function Ok x -> mf x | Error _ as r -> return r)
  let (>|=?) m f = m >|= (function Ok x -> f x | Error _ as r -> r)

  let driver_info = driver_info

  module Pg_io = struct

    let communicate db step =
      let aux fd =
        let rec loop = function
         | Pg.Polling_reading ->
            Unix.poll ~read:true fd >>= fun _ ->
            (match step () with
             | exception Pg.Error msg -> return (Error msg)
             | ps -> loop ps)
         | Pg.Polling_writing ->
            Unix.poll ~write:true fd >>= fun _ ->
            (match step () with
             | exception Pg.Error msg -> return (Error msg)
             | ps -> loop ps)
         | Pg.Polling_failed | Pg.Polling_ok ->
            return (Ok ())
        in
        loop Pg.Polling_writing
      in
      (match db#socket with
       | exception Pg.Error msg -> return (Error msg)
       | socket -> Unix.wrap_fd aux (Obj.magic socket))

    let get_next_result ~uri ~query db =
      let rec retry fd =
        db#consume_input;
        if db#is_busy then
          Unix.poll ~read:true fd >>= (fun _ -> retry fd)
        else
          return (Ok db#get_result)
      in
      try Unix.wrap_fd retry (Obj.magic db#socket)
      with Pg.Error err ->
        let msg = extract_communication_error db err in
        return (Error (Caqti_error.request_failed ~uri ~query msg))

    let get_one_result ~uri ~query db =
      get_next_result ~uri ~query db >>=? function
       | None ->
          let msg = Caqti_error.Msg "No response received after send." in
          return (Error (Caqti_error.request_failed ~uri ~query msg))
       | Some result ->
          return (Ok result)

    let get_final_result ~uri ~query db =
      get_one_result ~uri ~query db >>=? fun result ->
      get_next_result ~uri ~query db >>=? function
       | None ->
          return (Ok result)
       | Some _ ->
          let msg = Caqti_error.Msg "More than one response received." in
          return (Error (Caqti_error.response_rejected ~uri ~query msg))

    let check_query_result ~uri ~query ~row_mult ~single_row_mode result =
      let reject msg =
        let msg = Caqti_error.Msg msg in
        Error (Caqti_error.response_rejected ~uri ~query msg)
      in
      let fail msg =
        let msg = Caqti_error.Msg msg in
        Error (Caqti_error.request_failed ~uri ~query msg)
      in
      (match result#status with
       | Pg.Command_ok ->
          (match Caqti_mult.expose row_mult with
           | `Zero -> Ok ()
           | (`One | `Zero_or_one | `Zero_or_more) ->
              reject "Tuples expected for this query.")
       | Pg.Tuples_ok ->
          if single_row_mode then
            if result#ntuples = 0 then Ok () else
            reject "Tuples returned in single-row-mode."
          else
          (match Caqti_mult.expose row_mult with
           | `Zero ->
              if result#ntuples = 0 then Ok () else
              reject "No tuples expected for this query."
           | `One ->
              if result#ntuples = 1 then Ok () else
              ksprintf reject "Received %d tuples, expected one."
                       result#ntuples
           | `Zero_or_one ->
              if result#ntuples <= 1 then Ok () else
              ksprintf reject "Received %d tuples, expected at most one."
                       result#ntuples
           | `Zero_or_more -> Ok ())
       | Pg.Empty_query -> fail "The query was empty."
       | Pg.Bad_response ->
          let msg = extract_result_error result in
          Error (Caqti_error.response_rejected ~uri ~query msg)
       | Pg.Fatal_error ->
          let msg = extract_result_error result in
          Error (Caqti_error.request_failed ~uri ~query msg)
       | Pg.Nonfatal_error -> Ok () (* TODO: Log *)
       | Pg.Copy_out | Pg.Copy_in | Pg.Copy_both ->
          reject "Received unexpected copy response."
       | Pg.Single_tuple ->
          if not single_row_mode then
            reject "Received unexpected single tuple response." else
          if result#ntuples <> 1 then
            reject "Expected a single row in single-row mode." else
          Ok ())

    let check_command_result ~uri ~query result =
      check_query_result
        ~uri ~query ~row_mult:Caqti_mult.zero ~single_row_mode:false result
  end

  (* Driver Interface *)

  module type CONNECTION = Caqti_connection_sig.S
    with type 'a future := 'a System.future
     and type ('a, 'err) stream := ('a, 'err) System.Stream.t

  module Make_connection_base
    (Connection_arg : sig
      val env : Caqti_driver_info.t -> string -> Caqti_query.t
      val uri : Uri.t
      val db : Pg.connection
      val use_single_row_mode : bool
    end) =
  struct
    open Connection_arg

    let env' = env driver_info

    module Copy_encoder = Make_encoder (struct

      let encode_string s =
        let buf = Buffer.create (String.length s) in
        for i = 0 to String.length s - 1 do
          (match s.[i] with
           | '\\' -> Buffer.add_string buf "\\\\"
           | '\n' -> Buffer.add_string buf "\\n"
           | '\r' -> Buffer.add_string buf "\\r"
           | '\t' -> Buffer.add_string buf "\\t"
           | c -> Buffer.add_char buf c)
        done;
        Buffer.contents buf

      let encode_octets s = encode_string (db#escape_bytea s)
    end)

    let in_use = ref false
    let in_transaction = ref false
    let prepare_cache : prepared Int_hashtbl.t = Int_hashtbl.create 19

    let query_name_of_id = sprintf "_caq%d"

    let wrap_pg ~query f =
      try Ok (f ()) with
       | Postgresql.Error err ->
          let msg = extract_communication_error db err in
          Error (Caqti_error.request_failed ~uri ~query msg)

    let reset () =
      Log.warn (fun p ->
        p "Lost connection to <%a>, reconnecting." Caqti_error.pp_uri uri)
        >>= fun () ->
      in_transaction := false;
      (match db#reset_start with
       | exception Pg.Error _ -> return false
       | true ->
          Int_hashtbl.clear prepare_cache;
          Pg_io.communicate db (fun () -> db#reset_poll) >|=
          (function
           | Error _ -> false
           | Ok () -> (try db#status = Pg.Ok with Pg.Error _ -> false))
       | false ->
          return false)

    let rec retry_on_connection_error ?(n = 1) f =
      if !in_transaction then f () else
      (f () : (_, [> Caqti_error.call]) result future) >>=
      (function
       | Ok _ as r -> return r
       | Error (`Request_failed
            {Caqti_error.msg = Connection_error_msg
              {error = Postgresql.Connection_failure _; _}; _})
            as r when n > 0 ->
          reset () >>= fun reset_ok ->
          if reset_ok then
            retry_on_connection_error ~n:(n - 1) f
          else
            return r
       | Error _ as r -> return r)

    let send_oneshot_query
          ?params ?param_types ?binary_params ?(single_row_mode = false)
          query =
      retry_on_connection_error begin fun () ->
        return @@ wrap_pg ~query begin fun () ->
          db#send_query ?params ?param_types ?binary_params query;
          if single_row_mode then db#set_single_row_mode;
          db#consume_input
        end
      end

    let send_prepared_query query_id prepared params =
      let {query; param_types; binary_params; single_row_mode; _} =
        prepared
      in
      retry_on_connection_error begin fun () ->
        begin
          if Int_hashtbl.mem prepare_cache query_id then return (Ok ()) else
          return @@ wrap_pg ~query begin fun () ->
            db#send_prepare ~param_types (query_name_of_id query_id) query;
            db#consume_input
          end >>=? fun () ->
          Pg_io.get_final_result ~uri ~query db >|=? fun result ->
          Pg_io.check_command_result ~uri ~query result |>? fun () ->
          Ok (Int_hashtbl.add prepare_cache query_id prepared)
        end >|=? fun () ->
        wrap_pg ~query begin fun () ->
          db#send_query_prepared
            ~params ~binary_params (query_name_of_id query_id);
          if single_row_mode then db#set_single_row_mode;
          db#consume_input
        end
      end

    let fetch_one_result ~query () = Pg_io.get_one_result ~uri ~query db
    let fetch_final_result ~query () = Pg_io.get_final_result ~uri ~query db

    let fetch_single_row ~query () =
      Pg_io.get_one_result ~uri ~query db >>=? fun result ->
      (match result#status with
       | Pg.Single_tuple ->
          assert (result#ntuples = 1);
          return (Ok (Some result))
       | Pg.Tuples_ok ->
          assert (result#ntuples = 0);
          Pg_io.get_next_result ~uri ~query db >|=?
          (function
           | None -> Ok None
           | Some _ ->
              let msg =
                Caqti_error.Msg "Extra result after final single-row result." in
              Error (Caqti_error.response_rejected ~uri ~query msg))
       | _ ->
          return @@ Result.map (fun () -> None) @@
          Pg_io.check_query_result
            ~uri ~query ~row_mult:Caqti_mult.zero_or_more ~single_row_mode:true
            result)

    module Response = struct

      type source =
        | Complete of Pg.result
        | Single_row

      type ('b, 'm) t = {
        row_type: 'b Caqti_type.t;
        source: source;
        query: string;
      }

      let returned_count = function
       | {source = Complete result; _} ->
          return (Ok result#ntuples)
       | {source = Single_row; _} ->
          return (Error `Unsupported)

      let affected_count = function
       | {source = Complete result; _} ->
          return (Ok (int_of_string result#cmd_tuples))
       | {source = Single_row; _} ->
          return (Error `Unsupported)

      let exec _ = return (Ok ())

      let find = function
       | {row_type; source = Complete result; _} ->
          return (decode_row ~uri row_type (result, 0))
       | {source = Single_row; _} ->
          assert false

      let find_opt = function
       | {row_type; source = Complete result; _} ->
          return begin
            if result#ntuples = 0 then Ok None else
            (match decode_row ~uri row_type (result, 0) with
             | Ok y -> Ok (Some y)
             | Error _ as r -> r)
          end
       | {source = Single_row; _} ->
          assert false

      let fold f {row_type; query; source} =
        let decode = decode_row ~uri row_type in
        (match source with
         | Complete result ->
            let n = result#ntuples in
            let rec loop i acc =
              if i = n then Ok acc else
              (match decode (result, i) with
               | Ok y -> loop (i + 1) (f y acc)
               | Error _ as r -> r)
            in
            fun acc -> return (loop 0 acc)
         | Single_row ->
            let rec loop acc =
              fetch_single_row ~query () >>=? function
               | None -> return (Ok acc)
               | Some result ->
                  (match decode (result, 0) with
                   | Ok y -> loop (f y acc)
                   | Error _ as r -> return r)
            in
            loop)

      let fold_s f {row_type; query; source} =
        let decode = decode_row ~uri row_type in
        (match source with
         | Complete result ->
            let n = result#ntuples in
            let rec loop i acc =
              if i = n then return (Ok acc) else
              (match decode (result, i) with
               | Ok y -> f y acc >>=? loop (i + 1)
               | Error _ as r -> return r)
            in
            loop 0
         | Single_row ->
            let rec loop acc =
              fetch_single_row ~query () >>=? function
               | None -> return (Ok acc)
               | Some result ->
                  (match decode (result, 0) with
                   | Ok y -> f y acc >>=? loop
                   | Error _ as r -> return r)
            in
            loop)

      let iter_s f {row_type; query; source} =
        let decode = decode_row ~uri row_type in
        (match source with
         | Complete result ->
            let n = result#ntuples in
            let rec loop i =
              if i = n then return (Ok ()) else
              (match decode (result, i) with
               | Ok y -> f y >>=? fun () -> loop (i + 1)
               | Error _ as r -> return r)
            in
            loop 0
         | Single_row ->
            let rec loop () =
              fetch_single_row ~query () >>=? function
               | None -> return (Ok ())
               | Some result ->
                  (match decode (result, 0) with
                   | Ok y -> f y >>=? fun () -> loop ()
                   | Error _ as r -> return r)
            in
            loop ())

      let to_stream {row_type; query; source} =
        let decode = decode_row ~uri row_type in
        (match source with
         | Complete result ->
            let n = result#ntuples in
            let rec seq i () =
              if i = n then return Stream.Nil else
              (match decode (result, i) with
               | Ok y -> return (Stream.Cons (y, seq (i + 1)))
               | Error err -> return (Stream.Error err))
            in
            seq 0
         | Single_row ->
            let rec seq () =
              fetch_single_row ~query () >|= function
               | Ok None -> Stream.Nil
               | Ok (Some result) ->
                  (match decode (result, 0) with
                   | Ok y -> Stream.Cons (y, seq)
                   | Error err -> Stream.Error err)
               | Error err -> Stream.Error err
            in
            seq)
    end

    let type_oid_cache = Hashtbl.create 19

    let pp_request_with_param ppf =
      Caqti_request.make_pp_with_param ~env ~driver_info () ppf

    let call' ~f req param =
      Log.debug ~src:Logging.request_log_src (fun f ->
        f "Sending %a" pp_request_with_param (req, param)) >>= fun () ->

      let single_row_mode =
        use_single_row_mode
          && Caqti_mult.can_be_many (Caqti_request.row_mult req)
      in

      (* Prepare, if requested, and send the query. *)
      let param_type = Caqti_request.param_type req in
      (match Caqti_request.query_id req with
       | None ->
          let templ = Caqti_request.query req driver_info in
          let query = Pg_ext.query_string ~env:env' db templ in
          let param_length = Caqti_type.length param_type in
          let param_types = Array.make param_length 0 in
          let binary_params = Array.make param_length false in
          init_param_types
              ~uri ~type_oid_cache param_types binary_params param_type
            |> return >>=? fun () ->
          let params = Array.make param_length Pg.null in
          (match Param_encoder.encode ~uri params param_type param with
           | Ok () ->
              send_oneshot_query ~params ~binary_params ~single_row_mode query
                >|=? fun () ->
              Ok query
           | Error _ as r ->
              return r)
       | Some query_id ->
          begin
            try Ok (Int_hashtbl.find prepare_cache query_id) with
             | Not_found ->
                let templ = Caqti_request.query req driver_info in
                let query = Pg_ext.query_string ~env:env' db templ in
                let param_length = Caqti_type.length param_type in
                let param_types = Array.make param_length 0 in
                let binary_params = Array.make param_length false in
                init_param_types
                    ~uri ~type_oid_cache param_types binary_params param_type
                  |>? fun () ->
                Ok {query; param_length; param_types; binary_params;
                    single_row_mode}
          end |> return >>=? fun prepared ->
          let params = Array.make prepared.param_length Pg.null in
          (match Param_encoder.encode ~uri params param_type param with
           | Ok () ->
              send_prepared_query query_id prepared params >|=? fun () ->
              Ok prepared.query
           | Error _ as r ->
              return r))
        >>=? fun query ->

      (* Fetch and process the result. *)
      let row_type = Caqti_request.row_type req in
      if single_row_mode then
        f Response.{row_type; query; source = Single_row}
      else begin
        let row_mult = Caqti_request.row_mult req in
        fetch_final_result ~query () >>=? fun result ->
        (match
            Pg_io.check_query_result
              ~uri ~query ~row_mult ~single_row_mode result
         with
         | Ok () -> f Response.{row_type; query; source = Complete result}
         | Error _ as r -> return r)
      end

    let rec fetch_type_oids : type a. a Caqti_type.t -> _ = function
     | Caqti_type.Unit -> return (Ok ())
     | Caqti_type.Field (Caqti_type.Enum name as field_type)
          when not (Hashtbl.mem type_oid_cache name) ->
        call' ~f:Response.find_opt Q.type_oid name >>=
        (function
         | Ok (Some oid) ->
            return (Ok (Hashtbl.add type_oid_cache name oid))
         | Ok None ->
            Log.warn (fun p ->
              p "Failed to query OID for enum %s." name) >|= fun () ->
            Error (Caqti_error.encode_missing ~uri ~field_type ())
         | Error (`Encode_rejected _ | `Decode_rejected _ |
                  `Response_failed _ as err) ->
            Log.err (fun p ->
              p "Failed to fetch obtain OID for enum %s due to: %a"
                name Caqti_error.pp err) >|= fun () ->
            Error (Caqti_error.encode_missing ~uri ~field_type ())
         | Error #Caqti_error.call as r ->
            return r)
     | Caqti_type.Field _ -> return (Ok ())
     | Caqti_type.Option t -> fetch_type_oids t
     | Caqti_type.Tup2 (t1, t2) ->
        fetch_type_oids t1 >>=? fun () ->
        fetch_type_oids t2
     | Caqti_type.Tup3 (t1, t2, t3) ->
        fetch_type_oids t1 >>=? fun () ->
        fetch_type_oids t2 >>=? fun () ->
        fetch_type_oids t3
     | Caqti_type.Tup4 (t1, t2, t3, t4) ->
        fetch_type_oids t1 >>=? fun () ->
        fetch_type_oids t2 >>=? fun () ->
        fetch_type_oids t3 >>=? fun () ->
        fetch_type_oids t4
     | Caqti_type.Custom {rep; _} -> fetch_type_oids rep
     | Caqti_type.Annot (_, t0) -> fetch_type_oids t0

    let using_db f =
      if !in_use then
        failwith "Invalid concurrent usage of PostgreSQL connection detected.";
      in_use := true;
      cleanup
        (fun () -> f () >|= fun res -> in_use := false; res)
        (fun () -> reset () >|= fun _ -> in_use := false)

    let call ~f req param = using_db @@ fun () ->
      fetch_type_oids (Caqti_request.param_type req) >>=? fun () ->
      call' ~f req param

    let deallocate req =
      (match Caqti_request.query_id req with
       | Some query_id ->
          if Int_hashtbl.mem prepare_cache query_id then
            begin
              let query = sprintf "DEALLOCATE _caq%d" query_id in
              send_oneshot_query query >>=? fun () ->
              fetch_final_result ~query () >|=? fun result ->
              Int_hashtbl.remove prepare_cache query_id;
              Pg_io.check_query_result
                ~uri ~query ~row_mult:Caqti_mult.zero ~single_row_mode:false
                result
            end
          else
            return (Ok ())
       | None ->
          failwith "deallocate called on oneshot request")

    let disconnect () = using_db @@ fun () ->
      try db#finish; return () with Pg.Error err ->
        Log.warn (fun p ->
          p "While disconnecting from <%a>: %s"
            Caqti_error.pp_uri uri (Pg.string_of_error err))

    let validate () = using_db @@ fun () ->
      db#consume_input;
      if (try db#status = Pg.Ok with Pg.Error _ -> false) then
        return true
      else
        reset ()

    let check f = f (try db#status = Pg.Ok with Pg.Error _ -> false)

    let exec q p = call ~f:Response.exec q p
    let start () = exec Q.start () >|=? fun () -> Ok (in_transaction := true)
    let commit () = in_transaction := false; exec Q.commit ()
    let rollback () = in_transaction := false; exec Q.rollback ()

    let set_statement_timeout t =
      let t_arg =
        (match t with
         | None -> 0
         | Some t -> max 1 (int_of_float (t *. 1000.0 +. 500.0)))
      in
      call ~f:Response.exec (Q.set_statement_timeout t_arg) ()

    let populate ~table ~columns row_type data =
      let query =
        sprintf "COPY %s (%s) FROM STDIN" table (String.concat "," columns)
      in
      let param_length = Caqti_type.length row_type in
      let fail msg =
        return
          (Error (Caqti_error.request_failed ~uri ~query (Caqti_error.Msg msg)))
      in
      let pg_error err =
        let msg = extract_communication_error db err in
        return (Error (Caqti_error.request_failed ~uri ~query msg))
      in
      let put_copy_data data =
        let rec loop fd =
          match db#put_copy_data data with
          | Pg.Put_copy_error ->
              fail "Unable to put copy data"
          | Pg.Put_copy_queued ->
              return (Ok ())
          | Pg.Put_copy_not_queued ->
              Unix.poll ~write:true fd >>= fun _ -> loop fd
        in
        (match db#socket with
         | exception Pg.Error msg -> pg_error msg
         | socket -> Unix.wrap_fd loop (Obj.magic socket))
      in
      let copy_row row =
        let params = Array.make param_length "\\N" in
        (match Copy_encoder.encode ~uri params row_type row with
         | Ok () ->
            return (Ok (String.concat "\t" (Array.to_list params)))
         | Error _ as r ->
            return r)
        >>=? fun param_string -> put_copy_data (param_string ^ "\n")
      in
      begin
        (* Send the copy command to start the transfer.
         * Skip checking that there is only a single result: while in copy mode
         * we can repeatedly get the latest result and it will always be
         * Copy_in, so checking for a single result would trigger an error.
         *)
        send_oneshot_query query >>=? fun () ->
        fetch_one_result ~query ()
        >>=? fun result ->
          (* We expect the Copy_in response only - turn other success responses
           * into errors, and delegate error handling.
           *)
          (match result#status with
           | Pg.Copy_in -> return (Ok ())
           | Pg.Command_ok -> fail "Received Command_ok when expecting Copy_in"
           | _ -> return (Pg_io.check_command_result ~uri ~query result))
        >>=? fun () -> System.Stream.iter_s ~f:copy_row data
        >>=? fun () ->
          (* End the copy *)
          let rec copy_end_loop fd =
            match db#put_copy_end () with
            | Pg.Put_copy_error ->
                fail "Unable to finalize copy"
            | Pg.Put_copy_not_queued ->
                Unix.poll ~write:true fd >>= fun _ -> copy_end_loop fd
            | Pg.Put_copy_queued ->
                return (Ok ())
          in
          (match db#socket with
           | exception Pg.Error msg -> pg_error msg
           | socket -> Unix.wrap_fd copy_end_loop (Obj.magic socket))
        >>=? fun () ->
          (* After ending the copy, there will be a new result for the initial
           * query.
           *)
        fetch_final_result ~query () >|=? Pg_io.check_command_result ~uri ~query
      end
  end

  let connect_prim ~env ~uri config =
    let conninfo = Pg_ext.conninfo_of_config config in
    (match new Pg.connection ~conninfo () with
     | exception Pg.Error err ->
        let msg = extract_connect_error err in
        return (Error (Caqti_error.connect_failed ~uri msg))
     | db ->
        Pg_io.communicate db (fun () -> db#connect_poll) >>=
        (function
         | Error err ->
            let msg = extract_communication_error db err in
            return (Error (Caqti_error.connect_failed ~uri msg))
         | Ok () ->
            (match db#status <> Pg.Ok with
             | exception Pg.Error err ->
                let msg = extract_communication_error db err in
                return (Error (Caqti_error.connect_failed ~uri msg))
             | true ->
                let msg = Caqti_error.Msg db#error_message in
                return (Error (Caqti_error.connect_failed ~uri msg))
             | false ->
                (match Caqti_config_map.find
                        Config_keys.notice_processing config with
                 | None -> ()
                 | Some v -> db#set_notice_processing v);
                let module B = Make_connection_base
                  (struct
                    let env = env
                    let uri = uri
                    let db = db
                    let use_single_row_mode =
                      config
                      |> Caqti_config_map.find Config_keys.use_single_row_mode
                      |> Option.value ~default:false
                  end)
                in
                let module Connection = struct
                  let driver_info = driver_info
                  let driver_connection = None
                  include B
                  include Connection_utils.Make_convenience (System) (B)
                end in
                Connection.exec Q.set_timezone_to_utc () >|=
                (function
                 | Ok () -> Ok (module Connection : CONNECTION)
                 | Error err -> Error (`Post_connect err)))))

  let connect ?(env = no_env) ~config uri =
    (match
      config
        |> Caqti_config_map.add_driver Config_keys.Driver_id
        |> Config_keys.add_uri uri
     with
     | Error (#Caqti_error.preconnect as err) -> return (Error err)
     | Ok config -> connect_prim ~env ~uri config)
end

let () =
  let open Caqti_platform_unix.Driver_loader in
  register "postgres" (module Connect_functor);
  register "postgresql" (module Connect_functor)
