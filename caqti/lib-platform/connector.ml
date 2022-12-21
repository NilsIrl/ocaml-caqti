(* Copyright (C) 2014--2022  Petter A. Urkedal <paurkedal@gmail.com>
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

let default_config = Caqti_config_map.empty

module Make_without_connect (System : System_sig.S) = struct
  type 'a future = 'a System.future

  module Pool = Pool.Make (System)
  module Stream = System.Stream

  module type CONNECTION = Caqti_connection_sig.S
    with type 'a future := 'a future
     and type ('a, 'err) stream := ('a, 'err) Stream.t

  type connection = (module CONNECTION)
end

let add_tweaks_version = function
 | None -> fun config -> config
 | Some x -> Caqti_config_map.add Caqti_config_keys.tweaks_version x

module Make_connect
  (System : System_sig.S)
  (Loader : Driver_sig.Loader
              with type 'a future := 'a System.future
               and type ('a, 'e) stream := ('a, 'e) System.Stream.t) =
struct
  include Make_without_connect (System)
  open System

  let (>>=?) m f = m >>= function Ok x -> f x | Error _ as r -> return r
  let (>|=?) m f = m >|= function Ok x -> (Ok (f x)) | Error _ as r -> r

  module type DRIVER = Driver_sig.S
    with type 'a future := 'a future
     and type ('a, 'err) stream := ('a, 'err) Stream.t

  let drivers : (string, (module DRIVER)) Hashtbl.t = Hashtbl.create 11

  let load_driver uri =
    (match Uri.scheme uri with
     | None ->
        let msg = "Missing URI scheme." in
        Error (Caqti_error.load_rejected ~uri (Caqti_error.Msg msg))
     | Some scheme ->
        (try Ok (Hashtbl.find drivers scheme) with
         | Not_found ->
            (match Caqti_driver_dynload.retry_with_library
                      Loader.load_driver ~uri scheme with
             | Ok driver ->
                Hashtbl.add drivers scheme driver;
                Ok driver
             | Error _ as r -> r)))

  let connect ?env ?(config = default_config) ?tweaks_version uri
      : ((module CONNECTION), _) result future =
    (match load_driver uri with
     | Ok driver ->
        let module Driver = (val driver) in
        let config = add_tweaks_version tweaks_version config in
        Driver.connect ?env ~config uri
     | Error err ->
        return (Error err))

  let with_connection ?env ?config ?tweaks_version uri f =
    connect ?env ?config ?tweaks_version uri >>=? fun ((module Db) as conn) ->
    try
      f conn >>= fun result -> Db.disconnect () >|= fun () -> result
    with exn ->
      Db.disconnect () >|= fun () -> raise exn

  let connect_pool
        ?max_size ?max_idle_size ?(max_use_count = Some 100) ?post_connect
        ?env ?(config = default_config) ?tweaks_version uri =
    let check_arg cond =
      if not cond then invalid_arg "Caqti_connect.Make.connect_pool"
    in
    (match max_size, max_idle_size with
     | None, None -> ()
     | Some max_size, None -> check_arg (max_size >= 0)
     | None, Some _ -> check_arg false
     | Some max_size, Some max_idle_size ->
        check_arg (max_size >= 0);
        check_arg (0 <= max_idle_size && max_idle_size <= max_size));
    (match load_driver uri with
     | Ok driver ->
        let module Driver = (val driver) in
        let config = add_tweaks_version tweaks_version config in
        let connect =
          (match post_connect with
           | None ->
              fun () ->
                (Driver.connect ?env ~config uri
                    :> (connection, _) result future)
           | Some post_connect ->
              fun () ->
                (Driver.connect ?env ~config uri
                    :> (connection, _) result future)
                  >>=? fun conn -> post_connect conn
                  >|=? fun () -> conn)
        in
        let disconnect (module Db : CONNECTION) = Db.disconnect () in
        let validate (module Db : CONNECTION) = Db.validate () in
        let check (module Db : CONNECTION) = Db.check in
        let di = Driver.driver_info in
        let max_size, max_idle_size =
          (match Caqti_driver_info.can_concur di, Caqti_driver_info.can_pool di,
                 max_idle_size with
           | true, true, _ ->     max_size, max_idle_size
           | true, false, _ ->    max_size, Some 0
           | false, true, Some 0 -> Some 1, Some 0
           | false, true, _ ->      Some 1, Some 1
           | false, false, _ ->     Some 1, Some 0)
        in
        let pool =
          Pool.create ?max_size ?max_idle_size ~max_use_count ~validate ~check
            connect disconnect
        in
        Ok pool
     | Error err ->
        Error err)
end
