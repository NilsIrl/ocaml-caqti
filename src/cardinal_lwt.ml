(* Copyright (C) 2014  Petter Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the OCaml static compilation exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 *)

include Cardinal.Make (struct

  type 'a io = 'a Lwt.t
  let (>>=) = Lwt.(>>=)
  let return = Lwt.return
  let fail = Lwt.fail

  module Log = struct
    let error_f q fmt = Lwt_log.error_f fmt
    let warning_f q fmt = Lwt_log.warning_f fmt
    let info_f q fmt = Lwt_log.info_f fmt
    let debug_f q fmt = Lwt_log.debug_f fmt
  end

  module Unix = struct
    type file_descr = Lwt_unix.file_descr
    let of_unix_file_descr fd = Lwt_unix.of_unix_file_descr fd
    let wait_read = Lwt_unix.wait_read
  end

  (* TODO: priority, idle shutdown *)
  module Pool = struct
    type 'a t = 'a Lwt_pool.t
    let create ?(max_size = 1) ?max_priority ?validate f =
      Lwt_pool.create max_size ?validate f
    let use ?priority f p = Lwt_pool.use p f
    let drain pool = assert false (* FIXME *)
  end

end)