(* Copyright (C) 2022--2023  Petter A. Urkedal <paurkedal@gmail.com>
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

(** Prerequisities for connecting to databases using Lwt

    This provides basics for {!Caqti_lwt_unix} and {!Caqti_mirage}. *)

(**/**)
module System = System (* for private use by caqti-lwt.unix and caqti-mirage *)
(**/**)

module Stream = System.Stream

module type CONNECTION = Caqti_connection_sig.S
  with type 'a future := 'a Lwt.t
   and type ('a, 'e) stream := ('a, 'e) Stream.t

type connection = (module CONNECTION)

val or_fail : ('a, [< Caqti_error.t]) result -> 'a Lwt.t
(** Converts an error to an Lwt future failed with a {!Caqti_error.Exn}
    exception holding the error. *)
