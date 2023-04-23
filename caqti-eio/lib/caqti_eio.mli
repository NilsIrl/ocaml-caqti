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

(** Establishing Connections for Eio without Unix

    This module provides connections to the PGX database for Eio applications.
    For other database systems, you will need {!Caqti_eio_unix}. *)

(**/**)
module System = System (* for private use by caqti-eio.unix *)
(**/**)

include Caqti_connect_sig.S
  with type 'a future := 'a
   and module Stream = System.Stream
   and module Pool = System.Pool
   and type 'a connect_fun := sw: Eio.Switch.t -> Eio.Stdenv.t -> Uri.t -> 'a
   and type 'a with_connection_fun := Eio.Stdenv.t -> Uri.t -> 'a

val or_fail : ('a, [< Caqti_error.t]) result -> 'a
(** Eliminates the error-case by raising {!Caqti_error.Exn}. *)
