
(* "Lexing" is the runtime for ocamllex-generated lexers. *)
open Ast

let rec interpret (e: expr) =
  match e with
  | ExpConst _ -> "CONSTEXP "
  | ExpBinop (e1, _, e2) -> interpret e1 ^ "BINOP " ^ interpret e2
  | ExpUnop (_, e) -> "UNOP " ^ interpret e

let process (line : string) =
  let linebuf = Lexing.from_string line in
  try
    (* Run the parser on this line of input. *)
    Printf.printf "%s\n%!" (interpret (Parser.main Lexer.token linebuf))
  with
  | Lexer.Error msg ->
      Printf.fprintf stderr "%s%!" msg
  | Parser.Error ->
      Printf.fprintf stderr "At offset %d: syntax error.\n%!" (Lexing.lexeme_start linebuf)

let process (optional_line : string option) =
  match optional_line with
  | None ->
      ()
  | Some line ->
      process line

let rec repeat channel =
  (* Attempt to read one line. *)
  let optional_line, continue = Lexer.line channel in
  process optional_line;
  if continue then
    repeat channel
  
let () =
  repeat (Lexing.from_channel stdin)
