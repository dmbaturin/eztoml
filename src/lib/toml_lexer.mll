(*
 * Copyright (c) 2021 Daniil Baturin
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *)

{

open Parser_utils
open Toml_parser

let lexing_error lexbuf msg =
  let line, column = Parser_utils.get_lexing_position lexbuf in
  raise (Parse_error (Some (line, column), msg))

exception Bad_unicode of (string * int)

let validate_unicode lexbuf s =
  let validate _ column character =
    match character with
    | `Malformed s -> raise (Bad_unicode (s, column))
    | _ -> ()
  in
  try Uutf.String.fold_utf_8 validate () s
  with Bad_unicode (c, column) ->
    let line, _ = Parser_utils.get_lexing_position lexbuf in
    let msg = Printf.sprintf "malformed UTF-8 character \"%s\" on line %d (column %d within the string or comment)"
      c line column
    in raise (Parse_error (None, msg))

(* "Date validation".

    The goal is to reject completely implausible dates,
    since deep validation (if the user wants to work with dates to begin with)
    can and should be done by a real calendar library.

    Exception handling is added just in case.
    In practice invalid integers shouldn't make it that far so int_of_string should work,
    and int_of_string is the only function that can fail there,
    but it's probably better to be on the safe side.
 *)
let valid_time hours minutes seconds =
  try
    ((int_of_string hours) <= 23) &&
    ((int_of_string minutes) <= 59) &&
    ((int_of_string seconds) <= 60) (* Leap second is a real thing. *)
  with _ -> false

let valid_date year month day =
  try
    let year, month, day =
      int_of_string year, int_of_string month, int_of_string day
    in
    (year >= 1) &&
    ((month >= 1) && (month <= 12)) &&
    (day >= 1) &&
    (if month = 2 then (day <= 29) else (day <= 31))
    (* || ((year = 1993) && (month = 9)) *)
  with _ -> false

let valid_timezone hours minutes =
  match (hours, minutes) with
  | Some hours, Some minutes -> begin
      try
        ((int_of_string hours) <= 23) &&
        ((int_of_string minutes) <= 59)
      with _ -> false
    end
  | _, _ ->
    (* They can only be both Some or both None.
       The latter happens when a datetime uses "Z" instead of a timezone,
       in that case the timezone doesn't need checking.
     *)
    true

let add_utf8_char lexbuf buf num_s =
  try
    let num = int_of_string ("0x" ^ num_s) in
    let uc = Uchar.of_int num in
    Buffer.add_utf_8_uchar buf uc
  with Invalid_argument _ | Failure _ ->
    lexing_error lexbuf @@ Printf.sprintf "\\u%s is not a valid UTF-8 character escape" num_s

let trim_left_newline s =
  let len = String.length s in
  if len = 0 then s else
  let first_char = String.get s 0 in
  match first_char with
  | '\n' -> String.sub s 1 (len - 1)
  | '\r' ->
    (* Is it a file with Windows newlines? *)
    if len > 1 then begin
      match (String.get s 1) with
      | '\n' -> String.sub s 2 (len - 1)
      | _ ->
        (* Better not to think why a string starts with a \r then. *)
        s
    end
    else s
  | _ -> s

let newlines lexbuf s =
  let newline lexbuf c =
    match c with
    | '\n' -> Lexing.new_line lexbuf
    | _ -> ()
  in String.iter (newline lexbuf) s

let move_position lexbuf n =
  let open Lexing in
  lexbuf.lex_curr_pos <- (lexbuf.lex_curr_pos + n)

(* Lexer hack for context tracking.

   The issue on hand is that TOML is not context-free
   and there are constructs that cannot be correctly interpreted without knowing
   where we are.

   For example, consider `[[false]]`. It can be either:
   * a header of an array of tables named "false"
   * a nested array that contains a single boolean value `false`

   Another issue is that keys can be anything. There are no reserved keywords
   and no unambiguous key regex. `true = false` is a valid key/value pair.
   Thus to allow all possible keys, we need to know which side of the `=` sign we are.

   The contexts are:
   * top level
     Parsing starts in this context.
     In the top level context, everything in square brackets is a table header,
     and everything else is a key.
   * value context
     Entered from the top level context when a `=` is seen after a key.
     In this context anything in square brackets is an array,
     and other values are interpreted in a typed manner.
   * array context
     Entered from value context when a square bracket is seen.
     

   That is why we introduce a context stack.

   Parsing starts in the virtual "top level" context signified by an empty stack.
 *)

type context = ConValue | ConInlineTable | ConInlineTableValue | ConArray
let context_stack : (context list) ref = ref []

let in_top_level () =
  !context_stack = []

let in_value () =
  match !context_stack with
  | ConValue :: _ -> true
  | _ -> false

let in_array () =
  match !context_stack with
  | ConArray :: _ -> true
  | _ -> false

let in_inline_table () =
  match !context_stack with
  | ConInlineTable :: _ -> true
  | _ -> false

let in_inline_table_value () =
  match !context_stack with
  | ConInlineTableValue :: _ -> true
  | _ -> false

let exit_context () =
  let cs = !context_stack in
  match cs with
  | [] -> failwith "Lexer is trying to exit the top level context"
  | _ :: cs' -> context_stack := cs'

let enter_value () = context_stack := (ConValue :: !context_stack)
let enter_array () = context_stack := (ConArray :: !context_stack)
let enter_inline_table () = context_stack := (ConInlineTable :: !context_stack)
let enter_inline_table_value () = context_stack := (ConInlineTableValue :: !context_stack)

}

(** Reusable numeric regexes *)

let t_digit = ['0'-'9']
let t_sign = ['+' '-']

(* Numbers must not have leading zeroes.
   Digits may be separated by a single underscore.
 *)
let t_integer_part  = '0' | ['1'-'9'] ('_'? t_digit+)*

(* >An exponent part is an E (upper or lower case) followed by an integer part
   >(which follows the same rules as decimal integer values but may include leading zeros).
 *)
let t_exponent = ['E' 'e'] t_sign? '0'* t_integer_part

(* This covers decimals (42, +42, -42)
   and prefixed base-2/8/16 integers (0xFF, 0o54, 0xDEAD_BEEF...)

   As the spec says:
   "Non-negative integer values may also be expressed in hexadecimal, octal, or binary.
    In these formats, leading + is not allowed and leading zeros are allowed (after the prefix)"
 *)

let t_bin_digit = ['0'-'1']
let t_bin_integer_part = t_bin_digit ('_'? t_bin_digit+)*

let t_oct_digit = ['0'-'7']
let t_oct_integer_part = t_oct_digit ('_'? t_oct_digit+)*

let t_hex_digit = ['0'-'9' 'a'-'f' 'A'-'F']
let t_hex_integer_part = t_hex_digit ('_'? t_hex_digit+)*

let t_integer =
  (t_sign as integer_sign)? t_integer_part 
| "0b" '0'* t_bin_integer_part
| "0o" '0'* t_oct_integer_part
| "0x" '0'* t_hex_integer_part

(* Numbers with an exponent are always interpreted as floats.
   The spec disallows floats with an implicit integer/fractional part, like 42. and .42,
   so we don't cover those cases.
  *)
let t_fractional_part = '.' t_digit ('_'? t_digit+)*
let t_float_number = t_integer_part ((t_fractional_part t_exponent?) | t_exponent)

(* >Special float values can also be expressed. They are always lowercase.

  Conveniently, the float_of_string function allows every special value string required by TOML:
  nan, +nan, -nan, inf, +inf, -inf

  +nan and -nan are both interpreted as just a nan

 *)
let t_float = (t_sign as float_sign)? ((t_float_number | "nan" | "inf") as float_value)

(* Date and time *)

let t_time =
  (t_digit t_digit as hours)   ':'
  (t_digit t_digit as minutes) ':'
  (t_digit t_digit as seconds)
  ('.' t_digit+)?

(* Timezone part: either Z/z (Zulu time = UTC) or offset: +05:45, -08:00... *)

let t_timezone =
  ('Z' | 'z') | (t_sign (t_digit t_digit as tz_hours) ':' (t_digit t_digit as tz_minutes))

(* Date part: 1970-01-01 *)
let t_date =
  (t_digit t_digit t_digit t_digit as year) '-'
  (t_digit t_digit as month)                '-'
  (t_digit t_digit as day)

(* For the sake of readability, you may replace the T delimiter between date and time with a space character
   (as permitted by RFC 3339 section 5.6).

   RFC 3339 explcitly allows lowercase 't' and 'z':
   > NOTE: Per [ABNF] and ISO8601, the "T" and "Z" characters in this
   > syntax may alternatively be lower case "t" or "z" respectively.
 *)
let t_local_datetime = t_date ('T' | 't' | ' ') t_time
let t_offset_datetime = t_date ('T' | 't' | ' ') t_time t_timezone


(* Unicode escape sequences, for \uXXXX and \uXXXXXXXX. *)
let t_unicode =
  (t_hex_digit t_hex_digit t_hex_digit t_hex_digit) |
  (t_hex_digit t_hex_digit t_hex_digit t_hex_digit
   t_hex_digit t_hex_digit t_hex_digit t_hex_digit)

let t_invalid_escape = '\\' ([^ ' ' '\t' '\r' '\n' 'b' 'n' 'f' 'r' 't' '\\'] as invalid_escape_char)

rule token = parse
(* Whitespace *)
| ('\n' | '\r' '\n')
  {
    (* The only universal statement about newlines -- they increase the line counter. *)
    Lexing.new_line lexbuf;

    match !context_stack with
    | (ConInlineTable :: _) | (ConInlineTableValue :: _) ->
      (* Inside inline tables, newlines shouldn't occur at all. *)
      lexing_error lexbuf "line breaks are not allowed inside inline tables"
    | ConArray :: _ ->
      (* Inside arrays, newlines don't matter at all. *)
      token lexbuf
    | ConValue :: _ ->
      (* In the value context, a newline means we are back to the top level context,
         so we emit a NEWLINE token to let the parser use it as a key/value pair separator. *)
      let () = exit_context () in
      NEWLINE
    | [] ->
      (* In the top level context, we just emit a newline as a statement terminator
         (it may terminate a table header ([table], [[tarray]]) or an empty statement. *)
      NEWLINE 
 }
| [' ' '\t']
  { token lexbuf }
(* Punctuation *)
| "="
  {
    let () =
      if in_top_level () then enter_value ()
      else if in_inline_table () then enter_inline_table_value ()
    in
    EQ 
  }
| '{'
  {
    let () = enter_inline_table () in
    LEFT_BRACE
  }
| '}'
  {
    let () =
      (* If we were in the last value of that table,
         we need to exit both the value context and the parent inline table context. *)
      if in_inline_table_value () then (exit_context (); exit_context())
      else exit_context ()
    in
    RIGHT_BRACE
  }
| '[' '['
  {
    (* The TOML spec doesn't say it explicitly
       whether whitespace between brackets in table array headers is allowed
       (i.e. whether `[ [t_array] ]` is valid syntax),
       but the prevalent behaviour of popular libs and the testsuite samples suggest that
       the de facto agreement is to treat `[[` and `]]` as a single token.

       The fun part, however, is that it's context-sensitive.
       In the top level context `[[` marks the start of a header of an array of tables,
       while in `foo = [[` it's a start of a nested array.

       Thus we need to make sure to correctly emit two left square bracket tokens
       when we see `[[` character sequence in a value context.
     *)
    if in_top_level () then TABLE_ARRAY_HEADER_START
    else let () = enter_array (); move_position lexbuf (~-1) in ARRAY_START
  }
| ']' ']'
  {
    if in_top_level () then TABLE_ARRAY_HEADER_END else
    if not (in_array ()) then lexing_error lexbuf "stray closing square bracket (])"
    else let () = exit_context (); move_position lexbuf (~-1) in ARRAY_END
  }
| '['
  {
    if in_top_level () then TABLE_HEADER_START
    else let () = enter_array () in ARRAY_START
  }
| ']'
  {
    if in_top_level () then TABLE_HEADER_END else
    let () = if in_array () then exit_context () in
    ARRAY_END
  }
| '.' { DOT }
| ','
  {
    let () = if in_inline_table_value () then exit_context () in
    COMMA
  }
(* Primitive values *)
| t_time as t
  {
    if valid_time hours minutes seconds then LOCAL_TIME(t) else
    lexing_error lexbuf @@ Printf.sprintf "%s is not a valid time" t
  }
| t_date as d
  { if valid_date year month day then LOCAL_DATE(d) else
    lexing_error lexbuf @@ Printf.sprintf "%s is not a valid date" d
  }
| t_local_datetime as dt
  {
    if (valid_date year month day) && (valid_time hours minutes seconds) then LOCAL_DATETIME(dt) else
    lexing_error lexbuf @@ Printf.sprintf "%s is not a valid local datetime" dt
  }
| t_offset_datetime as dt
  {
    if (valid_date year month day) && (valid_time hours minutes seconds) && (valid_timezone tz_hours tz_minutes)
    then OFFSET_DATETIME(dt)
    else lexing_error lexbuf @@ Printf.sprintf "%s is not a valid datetime" dt
  }
| t_integer as s
  {
    if not ((in_top_level ()) || (in_inline_table ())) then INTEGER s
    else if Option.is_some integer_sign then lexing_error lexbuf @@ Printf.sprintf "\"%s\" is not a valid key" s
    else KEY(s)
  }
| t_float as s
  {
    if not ((in_top_level ()) || (in_inline_table ())) then FLOAT s else
    (* If we are in the top level context, it's a key that looks like a float. *)
    if Option.is_some float_sign then lexing_error lexbuf @@ Printf.sprintf "\"%s\" is not a valid key" s
    else
    match float_value with
    | "nan" | "inf" -> KEY(float_value)
    | _ ->
      if Option.is_none @@ String.index_opt float_value '.' then KEY(float_value)
      else failwith "unimplemented"
  }
| ("true" | "false") as s
  (* Boolean literals must always be lowercase in TOML. *)
  {
    if (in_top_level ()) || (in_inline_table ()) then KEY(s)
    else BOOLEAN(s)
  }
(* Bare keys. CAUTION: this _must_ come after primitive values
   because integers and booleans match the same regex! *)
| ['A'-'Z''a'-'z''0'-'9''_''-']+ as s { KEY(s) }
| "'''''"
  { let buf = Buffer.create 512 in Buffer.add_string buf "''"; read_single_quoted_multiline_string buf lexbuf }
| "''''"
  { let buf = Buffer.create 512 in Buffer.add_string buf "'"; read_single_quoted_multiline_string buf lexbuf }
| "'''"
    { read_single_quoted_multiline_string (Buffer.create 512) lexbuf }
| '"' '"' '"' '"' '"'
  { let buf = Buffer.create 512 in Buffer.add_string buf "\"\""; read_double_quoted_multiline_string buf lexbuf }
| '"' '"' '"' '"'
  { let buf = Buffer.create 512 in Buffer.add_string buf "\""; read_double_quoted_multiline_string buf lexbuf }
| '"' '"' '"'
    { read_double_quoted_multiline_string (Buffer.create 512) lexbuf }
| '''
    { read_single_quoted_string (Buffer.create 512) lexbuf }
| '"'
    { read_double_quoted_string (Buffer.create 512) lexbuf }
| '#'
  {
    read_comment (Buffer.create 512) lexbuf;
  }
| eof
  {
    let () = context_stack := [] in
    EOF
  }
| _ as bad_char
  { lexing_error lexbuf (Printf.sprintf "unexpected character \'%s\'" (Char.escaped bad_char)) }

and read_comment buf =
  parse
  | ['\x00'-'\x08' '\x0B'-'\x1F' '\x7F'] as bad_char
      {
        lexing_error lexbuf @@
        Printf.sprintf "character '%s' is not allowed inside a comment"
        (Char.escaped bad_char)
      }
  | ('\n' | '\r' '\n')
    {
      (* This is for cases like `[foo.bar] # my table` or `foo = bar # my value`.

         Since in most contexts (except for the array context) newlines are significant,
         we cannot ignore a comment together with the newline that ends it.
         Instead we need to treat the trailing newline as a character of its own.
         Which is why we look for it to see if the comment has ended,
         but then move the lexing position back to allow that newline to be lexed
         as it should be in the parent context.
       *)
      let () = 
        validate_unicode lexbuf @@ Buffer.contents buf;
        move_position lexbuf (~-1)
      in
      token lexbuf
    }
  | [^ '\n' '\x00'-'\x08' '\x0B'-'\x1F' '\x7F']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf); read_comment buf lexbuf }

and read_double_quoted_string buf =
  parse
  | '"'
    {
      let str = Buffer.contents buf in
      let () = validate_unicode lexbuf str in
      if not (in_top_level ()) && not (in_inline_table ()) then STRING str
      else KEY str
    }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_double_quoted_string buf lexbuf }
  | '\\' 'b'  { Buffer.add_char buf '\b'; read_double_quoted_string buf lexbuf }
  | '\\' 'f'  { Buffer.add_char buf '\012'; read_double_quoted_string buf lexbuf }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_double_quoted_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_double_quoted_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_double_quoted_string buf lexbuf }
  | '\\' '\'' { Buffer.add_char buf '\''; read_double_quoted_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"'; read_double_quoted_string buf lexbuf }
  | ("\\u" | "\\U") (t_unicode as u) { add_utf8_char lexbuf buf u; read_double_quoted_string buf lexbuf }
  | '\\' [' ' '\t' '\n']* '\n' { newlines lexbuf (Lexing.lexeme lexbuf); read_double_quoted_string buf lexbuf }
  | t_invalid_escape
    {
      let msg = Printf.sprintf "\\%s is not a valid escape sequence" (Char.escaped invalid_escape_char) in
      lexing_error lexbuf msg
    }
  | '\n'      { lexing_error lexbuf "line breaks are not allowed inside strings" }
  | ['\x00'-'\x08' '\x0B'-'\x1F' '\x7F'] as bad_char
    { lexing_error lexbuf @@
        Printf.sprintf "character '%s' is not allowed inside a string literal without escaping"
        (Char.escaped bad_char) 
    }
  | [^ '"' '\\' '\n' '\x00'-'\x08' '\x0B'-'\x1F' '\x7F']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_double_quoted_string buf lexbuf
    }
  | eof { lexing_error lexbuf "Quoted string is missing the closing double quote" }

and read_single_quoted_string buf =
  parse
  | '''
    {
      let str = Buffer.contents buf in
      let () = validate_unicode lexbuf str in
      if not (in_top_level ()) && not (in_inline_table ()) then STRING str
      else KEY str
    }
  | '\\' [' ' '\t' '\n']* '\n' { newlines lexbuf (Lexing.lexeme lexbuf); read_single_quoted_string buf lexbuf }
  | '\n' { lexing_error lexbuf "line breaks are not allowed inside strings" }
  | ['\x00'-'\x08' '\x0B'-'\x1F' '\x7F'] as bad_char
    { lexing_error lexbuf @@
        Printf.sprintf "character '%s' is not allowed inside a string literal without escaping"
        (Char.escaped bad_char)
    }
  | [^ ''' '\n' '\x00'-'\x08' '\x0B'-'\x1F' '\x7F']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_single_quoted_string buf lexbuf
    }
  | eof { lexing_error lexbuf "Quoted string is missing the closing single quote" }

and read_double_quoted_multiline_string buf =
  parse
  | '"' '"' '"' '"' '"'
    {
      Buffer.add_string buf "\"\"";
      validate_unicode lexbuf @@ Buffer.contents buf;
      MULTILINE_STRING (Buffer.contents buf |> trim_left_newline) 
    }
  | '"' '"' '"' '"'
    {
      Buffer.add_string buf "\"";
      validate_unicode lexbuf @@ Buffer.contents buf;
      MULTILINE_STRING (Buffer.contents buf |> trim_left_newline)
    }
  | '"' '"' '"'
    { validate_unicode lexbuf @@ Buffer.contents buf; MULTILINE_STRING (Buffer.contents buf |> trim_left_newline) }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' 'b'  { Buffer.add_char buf '\b'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' 'f'  { Buffer.add_char buf '\012'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' '\'' { Buffer.add_char buf '\''; read_double_quoted_multiline_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"'; read_double_quoted_multiline_string buf lexbuf }
  | '\\' [' ' '\t' '\n']* '\n' { newlines lexbuf (Lexing.lexeme lexbuf); read_double_quoted_multiline_string buf lexbuf }
  | '\n'      { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; read_double_quoted_multiline_string buf lexbuf }
  | ("\\u" | "\\U") (t_unicode as u) { add_utf8_char lexbuf buf u; read_double_quoted_multiline_string buf lexbuf }
  | t_invalid_escape
    {
      let msg = Printf.sprintf "\\%s is not a valid escape sequence" (Char.escaped invalid_escape_char) in
      lexing_error lexbuf msg
    }
  | ['\x00'-'\x08' '\x0B'-'\x1F' '\x7F'] as bad_char
    {
       lexing_error lexbuf @@
         Printf.sprintf "character '%s' is not allowed inside a string literal without escaping"
         (Char.escaped bad_char)
    }
  | '"' [^ '"']
    { Buffer.add_string buf "\""; move_position lexbuf (~-1); read_double_quoted_multiline_string buf lexbuf }
  | '"' '"' [^ '"']
    { Buffer.add_string buf "\"\""; move_position lexbuf (~-1); read_double_quoted_multiline_string buf lexbuf }
  | [^ '"' '\x00'-'\x08' '\n' '\x0B'-'\x1F' '\x7F' '\\']+
    {
      Buffer.add_string buf (Lexing.lexeme lexbuf); 
      read_double_quoted_multiline_string buf lexbuf
    }
  | eof { lexing_error lexbuf "double-quoted multiline string is missing the closing double quotes" }

and read_single_quoted_multiline_string buf =
  parse
  | "'''''"
    {
      Buffer.add_string buf "''";
      validate_unicode lexbuf @@ Buffer.contents buf; 
      MULTILINE_STRING (Buffer.contents buf |> trim_left_newline)
    }
  | "''''"
    {
      Buffer.add_string buf "'";
      validate_unicode lexbuf @@ Buffer.contents buf;
      MULTILINE_STRING (Buffer.contents buf |> trim_left_newline)
    }
  | "'''"   { validate_unicode lexbuf @@ Buffer.contents buf; MULTILINE_STRING (Buffer.contents buf |> trim_left_newline) }
  | '\\' [' ' '\t' '\n']* '\n' { newlines lexbuf (Lexing.lexeme lexbuf); read_single_quoted_multiline_string buf lexbuf }
  | '\n'    { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; read_single_quoted_multiline_string buf lexbuf }
  | ['\x00'-'\x08' '\x0B'-'\x1F' '\x7F'] as bad_char
    { lexing_error lexbuf @@
        Printf.sprintf "character '%s' is not allowed inside a string literal without escaping"
        (Char.escaped bad_char)
    }
  | (''' [^ '''] | ''' ''' [^ ''']  | [^ ''' '\x00'-'\x08' '\x0B'-'\x1F' '\x7F']+)
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_single_quoted_multiline_string buf lexbuf
    }
  | eof { lexing_error lexbuf "single-quoted multiline string is missing the closing single quotes" }

