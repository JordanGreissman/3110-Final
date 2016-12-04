open CamomileLibrary
open Exception

type state = State.t

let draw_map ctx w h x_offset (s:State.t) =
  let edge_style = {
    LTerm_style.none with foreground = (Some LTerm_style.red)
  } in
  let selected_edge_style = {
    LTerm_style.none with
    foreground = (Some LTerm_style.yellow);
    background = (Some LTerm_style.yellow);
  } in
  let none_style = {
    LTerm_style.none with
    foreground = (Some LTerm_style.black);
    background = (Some LTerm_style.black);
  } in
  LTerm_draw.clear ctx;
  for y = 0 to h do
    for x = 0 to w do
      (* the cell we're currently drawing in absolute lambda-term coords *)
      let delta = Coord.Screen.create x y in
      let screen_cur = Coord.Screen.add s.screen_top_left delta in
      (* the hex or hexes containing that cell *)
      match Coord.offset_from_screen screen_cur with
      (* we're inside a hex *)
      | Contained c ->
        let t = Mapp.tile_by_pos c s.map in
        let cell = Tile.get_art_char screen_cur t in
        let style = match cell with
          | Some c ->
            { LTerm_style.none with foreground = Some (Art.get_color c) }
          | None -> none_style in
        let ch = match cell with
          | Some c -> Art.get_char c
          | None   -> 'x' in
        LTerm_draw.draw_char ctx y x ~style (UChar.of_char ch)
        (* LTerm_draw.draw_char ctx y x (UChar.of_char '~') *)
      (* we're on the border between two hexes *)
      | Border (h1,h2,h3) ->
        let selected = s.selected_tile in
        let is_selected =
          (h1 = selected) ||
          (match h2 with Some c when c = selected -> true | _ -> false) ||
          (match h3 with Some c when c = selected -> true | _ -> false) in
        let style = if is_selected then selected_edge_style else edge_style in
        LTerm_draw.draw_char ctx y x ~style (UChar.of_char '.')
      (* we're off the edge of the map *)
      | None ->
        LTerm_draw.draw_char ctx y x ~style:none_style (UChar.of_char 'x')
    done
  done

let draw_ascii_frame ctx w h =
  for i = 1 to (w-1) do
    LTerm_draw.draw_char ctx 0     i (UChar.of_char '-');
    LTerm_draw.draw_char ctx (h-1) i (UChar.of_char '-')
  done;
  for i = 1 to (h-1) do
    LTerm_draw.draw_char ctx i 0     (UChar.of_char '|');
    LTerm_draw.draw_char ctx i (w-1) (UChar.of_char '|')
  done;
  LTerm_draw.draw_char ctx 0     0     (UChar.of_char '+');
  LTerm_draw.draw_char ctx (h-1) 0     (UChar.of_char '+');
  LTerm_draw.draw_char ctx 0     (w-1) (UChar.of_char '+');
  LTerm_draw.draw_char ctx (h-1) (w-1) (UChar.of_char '+')

let draw_messages ctx w h messages =
  LTerm_draw.clear ctx;
  (* draw an ascii box because the built-in boxes don't work on OSX *)
  draw_ascii_frame ctx w h;
  (* draw the messages *)
  for i = 1 to min (h-2) (List.length messages) do
    let m = (List.nth messages (i-1)) in
    let style = match Message.get_kind m with
      | Message.Info -> LTerm_style.none
      | Message.ImportantInfo ->
        { LTerm_style.none with foreground = Some (LTerm_style.blue) }
      | Message.Illegal ->
        { LTerm_style.none with foreground = Some (LTerm_style.red) }
      | Message.Win ->
        { LTerm_style.none with foreground = Some (LTerm_style.yellow) } in
    LTerm_draw.draw_string ctx i 1 ~style:style (Message.get_text m)
  done

let draw_resources ctx w h resources =
  let key_style = { LTerm_style.none with foreground = Some (LTerm_style.blue) } in
  LTerm_draw.draw_string ctx 3 1 "Resources:";
  for y = 0 to 3 do
    let (resource, amount) = List.nth resources y in
    LTerm_draw.draw_string ctx (y + 5) 2 (
      if y = 3 then
        (Resource.res_to_str resource)^": "^(string_of_int amount)
      else
        (Resource.res_to_str resource)^":  "^(string_of_int amount));
  done

let draw_menu ctx w h menu turn civs =
  let player = List.nth civs 0 in
  let resources = Civ.get_resources player in
  let key_style = { LTerm_style.none with foreground = Some (LTerm_style.blue) } in
  LTerm_draw.clear ctx;
  draw_ascii_frame ctx w h;
  LTerm_draw.draw_string ctx 1 1 ("Turn: "^(string_of_int turn));
  LTerm_draw.draw_string ctx 10 1 "Menu:";

  draw_resources ctx w h resources;
  for y = 1 to (min (List.length menu) h) do
    let item : Menu.t = List.nth menu (y-1) in
    let c = match item.key with
      | Char c -> c
      | e -> raise (Critical (
          "interface",
          "draw_menu",
          "Unexpected key input: " ^
          (LTerm_key.to_string {control=false;meta=false;shift=false;code=e}))) in
    LTerm_draw.draw_string ctx (y+11) 1 " [";
    LTerm_draw.draw_char ctx (y+11) 3 ~style:key_style c;
    LTerm_draw.draw_string ctx (y+11) 4 (Printf.sprintf "] %s" item.text)
  done

(* NOTE lambda-term coordinates are given y first, then x *)
let draw s ui matrix =
  let message_box_height = 10 in
  let menu_width = 20 in
  let size = LTerm_ui.size ui in
  let w,h = LTerm_geom.((cols size),(rows size)) in
  let ctx = LTerm_draw.context matrix size in
  let map_ctx = LTerm_draw.sub ctx {row1=0;row2=(h-message_box_height);col1=menu_width;col2=w} in
  let message_ctx = LTerm_draw.sub ctx {row1=(h-message_box_height);row2=h;col1=0;col2=w} in
  let menu_ctx = LTerm_draw.sub ctx {row1=0;row2=(h-message_box_height);col1=0;col2=menu_width} in
  draw_map map_ctx (w-menu_width) (h-message_box_height) menu_width !s;
  draw_messages message_ctx w message_box_height !s.messages;
  draw_menu menu_ctx menu_width (h-message_box_height) !s.menu !s.turn !s.civs
