open Yojson
open Lwt
open CamomileLibrary
open Civ
open State
open Exception
open Cmd
open LTerm_event

type civ = Civ.t
type menu = Menu.t

type parsed_json = {
  turns: int;
  ai: int;
  entities: Entity.role list;
  hubs: Hub.role list;
  civs: (string * string) list;
  tech_tree: Research.Research.research_list;
}

type win_state = Military | Tech | Score | Tie | No_Win

let dispatch_message (state:State.t) s k =
  let m = Message.create s k in
  { state with messages = m::state.messages }

(* Error handling necessary? *)
let load_json s =
  try Yojson.Basic.from_file s with
  | _ -> raise (Critical ("game",
                          "load_json",
                          "File does not exist or is not a JSON"))

let get_assoc s json =
  json |> Yojson.Basic.Util.member s
  |> Basic.Util.to_list |> Basic.Util.filter_assoc

let extract_list str lst =
  let json_list = List.assoc str lst |> Basic.Util.to_list in
  Basic.Util.filter_map (Basic.Util.to_string_option) json_list

let extract_game assoc =
  let turns = (List.assoc "turns" assoc) |> Basic.Util.to_int in
  let ai = (List.assoc "ai" assoc) |> Basic.Util.to_int in
  (turns, ai)

let extract_techs entity_role_list hub_role_list assoc =
  let tech = (List.assoc "tech" assoc) |> Basic.Util.to_string in
  let resource = (List.assoc "resource" assoc) |> Basic.Util.to_string in
  let cost = (List.assoc "cost" assoc) |> Basic.Util.to_int in
  let treasure = (List.assoc "treasure" assoc) |> Basic.Util.to_list
                 |> Basic.Util.filter_assoc in
  let treasure = List.nth treasure 0 in
  let hub = (List.assoc "hub" treasure) |> Basic.Util.to_string in
  let amount = (List.assoc "amount" treasure) |> Basic.Util.to_int in
  let entity = extract_list "entity" treasure in
  Research.Research.extract_to_value tech resource cost hub amount
    entity entity_role_list hub_role_list

let extract_unlockable entity_role_list hub_role_list assoc =
  let branch = (List.assoc "branch" assoc) |> Basic.Util.to_string in
  let techs = (List.assoc "techs" assoc) |> Basic.Util.to_list
              |> Basic.Util.filter_assoc in
  let techs = List.map (extract_techs entity_role_list hub_role_list) techs in
  (branch, techs)

let extract_hub entity_role_list assoc =
  let name = (List.assoc "name" assoc) |> Basic.Util.to_string in
  let desc = (List.assoc "desc" assoc) |> Basic.Util.to_string in
  let builder = (List.assoc "built by" assoc) |> Basic.Util.to_string in
  let defense = (List.assoc "defense" assoc) |> Basic.Util.to_int in
  let cost = (List.assoc "cost" assoc) |> Basic.Util.to_int in
  let entities = extract_list "entities" assoc in
  let generates = (List.assoc "generates" assoc) |> Basic.Util.to_list
                  |> Basic.Util.filter_assoc in
  let generates = List.nth generates 0 in
  let resource = (List.assoc "resource" generates) |> Basic.Util.to_string in
  let amount = (List.assoc "amount" generates) |> Basic.Util.to_int in
  Hub.extract_to_role name desc builder defense cost
    resource amount entities entity_role_list

let extract_civ assoc =
  let name = (List.assoc "name" assoc) |> Basic.Util.to_string in
  let desc = (List.assoc "desc" assoc) |> Basic.Util.to_string in
  (name, desc)

let extract_entity assoc =
  let name = (List.assoc "name" assoc) |> Basic.Util.to_string in
  let desc = (List.assoc "desc" assoc) |> Basic.Util.to_string in
  let attack = (List.assoc "attack" assoc) |> Basic.Util.to_int in
  let defense = (List.assoc "defense" assoc) |> Basic.Util.to_int in
  let actions = (List.assoc "actions" assoc) |> Basic.Util.to_int in
  let cost = (List.assoc "cost" assoc) |> Basic.Util.to_int in
  let requires = (List.assoc "requires" assoc) |> Basic.Util.to_string in
  Entity.extract_to_role name desc requires cost attack defense actions

let init_json json =
  let meta = json |> Yojson.Basic.Util.member "game"
             |> Basic.Util.to_assoc |> extract_game in
  let entities = List.map extract_entity
      (get_assoc "entities" json) in
  let hubs = List.map (extract_hub entities)
      (get_assoc "hubs" json) in
  let unlockables = List.map (extract_unlockable entities hubs)
      (get_assoc "techtree" json) in
  let branches = List.map fst unlockables in
  let techs = List.map snd unlockables in
  let tree = Research.Research.create_tree branches techs [] in
  let civs = List.map extract_civ
      (get_assoc "civilizations" json) in
  {turns = fst meta; ai = snd meta; entities = entities; hubs = hubs;
   tech_tree = tree; civs = civs}

let init_civ player_controlled parsed map unlocked civ : civ =
  let entity_roles = parsed.entities in
  let hub_roles = parsed.hubs in
  let tech_tree = parsed.tech_tree in
  let starting_tile = Mapp.get_random_tile !map in
  let tiles = Mapp.get_adjacent_tiles !map starting_tile in
  let tile = Random.self_init ();
    List.nth (tiles) (Random.int (List.length tiles)) in
  let tup = Cluster.create
      ~name:(fst civ)
      ~descr:"A soon to be booming metropolis"
      ~town_hall_tile:starting_tile
      ~hub_role_list:hub_roles
      ~map:!map in
  let role = Entity.find_role "worker" entity_roles in
  let worker = Entity.create role (Tile.get_pos tile) 0 in
  let map' = Mapp.set_tile (Tile.set_entity tile (Some worker))
      (snd tup) in
  map := map';
  {
    name = fst civ;
    desc = snd civ;
    entities = [worker];
    pending_entities = [];
    pending_hubs = [];
    unlocked_entities = [];
    resources = [(Food, 0); (Gold, 0); (Iron, 0); (Paper, 0)];
    clusters = [fst tup];
    techs = tech_tree;
    player_controlled = player_controlled;
    next_id = 1;
  }

let get_player_start_coords civs =
  let player = List.find Civ.get_player_controlled civs in
  let cluster = List.nth player.clusters 0 in
  let c = Tile.get_pos (Cluster.get_town_hall cluster) in
  let coord = Coord.screen_from_offset c in
  let origin = List.nth (List.nth coord 0) 0 in
  let offset = Coord.Screen.create (-5) (-2) in
  (c, Coord.Screen.add offset origin)

let init_state json : State.t =
  let json = Basic.from_file json in
  let parsed = init_json json in
  let map = ref (Mapp.generate 42 42) in
  let unlocked = List.map (fun (k, v) ->
      Research.Research.get_unlocked k parsed.tech_tree)
      parsed.tech_tree in
  let unlocked = List.flatten unlocked in
  let civs = List.mapi
      (fun i civ -> init_civ (i=0) parsed map unlocked civ)
      parsed.civs in
  let coords = get_player_start_coords civs in
  {
    civs = civs;
    turn = 1;
    total_turns = parsed.turns;
    hub_roles = parsed.hubs;
    entity_roles = parsed.entities;
    tech_tree = parsed.tech_tree;
    map = !map;
    screen_top_left = snd coords;
    selected_tile = fst coords;
    messages = [];
    is_quit = false;
    menu = Menu.main_menu;
    pending_cmd = None;
    current_civ = 0;
  }

let rec add_hubs clusters map hubs =
  match hubs with
  | [] -> clusters
  | h::t -> add_hubs (Cluster.add_hub clusters map h) map t

let check_for_win s =
  let check_conditions s =
    let civs = State.get_civs s in
    (* TODO *)
    let check_points civs =
      let points = List.map score civs in
      let rec fold_points i max lst =
        match lst with
        | [] -> [i]
        | h::t -> if h > max then fold_points (i + 1) h t
                  else if h = max then (i::(fold_points (i + 1) h t))
                  else fold_points i max t in
      let indexes = fold_points 0 0 points in
      List.map (fun x -> List.nth civs x) indexes
    in

    let check_tech civs =
      List.filter (fun x -> Research.Research.check_complete x.techs) civs
    in

    let rec get_winners civs =
      match civs with
      | [] -> []
      | (Some (x, y))::t -> (x, y)::(get_winners t)
      | _ -> raise (Critical ("game","get_winners","Could not get winners"))
    in

    let tech_win = let civs = check_tech civs in
      match List.length civs with
      | 0 -> []
      | _ -> List.map
               (fun (x:Civ.t) -> Some (x.name, x.player_controlled)) civs in
    let military_win = if List.length civs = 1 then
        (let civ = List.nth civs 0 in
         Some (civ.name, civ.player_controlled))
      else None in
    let score_win = if s.turn = s.total_turns then
        (let civs = check_points civs in
         match List.length civs with
         | 0 -> []
         | _ ->
           List.map (fun x -> Some (x.name, x.player_controlled)) civs)
      else [] in
    match (score_win, military_win, tech_win) with
    | ([], None, []) -> ([], No_Win)
    | ((Some (x, y))::t, None, []) -> begin match t with
        | [] -> ([(x, y)], Score)
        | _ -> (get_winners score_win, Tie)
      end
    | ([], Some (x, y), []) -> ([(x, y)], Score)
    | ([], None, (Some (x, y))::t) ->  begin match t with
        | [] -> ([(x, y)], Tech)
        | _ -> (get_winners tech_win, Tie)
      end
    | (a, Some (x, y), []) -> ((x, y)::(get_winners a), Tie)
    | ([], Some (x, y), b) -> ((x, y)::(get_winners b), Tie)
    | (a, None, b) -> ((get_winners a)@(get_winners b), Tie)
    | (a, Some (x, y), b) -> ((x, y)::(get_winners a)@(get_winners b), Tie)
  in

  let conditions_met = check_conditions s in
  match conditions_met with
  | (_, No_Win) -> s
  | (civs, condition) when condition = Tie -> (* TODO print victory message *)
    {s with is_quit = true}
  | (civ, condition) -> match condition with
    (* TODO print victory message *)
    | Military -> {s with is_quit = true}
    | Score -> {s with is_quit = true}
    | Tech -> {s with is_quit = true}
    | _ -> raise (Critical ("game","check_for_win","Error deciding winner"))(* or here *)

let place_entity_on_map s entity =
  let state = !s in
  let tile = Mapp.tile_by_pos (Entity.get_pos entity) state.map in
  let tile = Mapp.get_nearest_available_tile tile state.map in
  let entity = Entity.set_pos (Tile.get_pos tile) entity in
  let map' = Mapp.set_tile (Tile.set_entity tile (Some entity)) state.map in
  s := {state with map=map'}; entity

let place_hub_on_map s hub =
  let state = !s in
  let tile = Mapp.tile_by_pos (Hub.get_position hub) state.map in
  let map' = Mapp.set_tile (Tile.set_hub tile (Some hub)) state.map in
  s := {state with map=map'}; hub

let tick_pending s civ =
  let map = s.map in
  let ticked = List.map Entity.tick_cost civ.pending_entities in
  let done_entities = List.filter
      Entity.is_done ticked in
  let done_entities = List.map (place_entity_on_map (ref s)) done_entities in
  let entities = done_entities@civ.entities in
  let pending_entities = List.filter
      (fun x -> not (Entity.is_done x)) ticked in
  let ticked = List.map Hub.tick_cost civ.pending_hubs in
  let done_hubs = List.map (place_hub_on_map (ref s))
    (List.filter Hub.is_done civ.pending_hubs) in
  let clusters = add_hubs civ.clusters map done_hubs in
  let pending_hubs = List.filter
      (fun x -> not (Hub.is_done x)) ticked in
  let civ = get_resource_for_turn civ in
  {civ with entities=entities;
            pending_entities=pending_entities;
            clusters=clusters;
            pending_hubs=pending_hubs;}

let next_turn s =
  let civs = State.get_civs s in
  let s = Ai.attempt_turns civs (ref s) in
  let civs = List.map (tick_pending s) (State.get_civs s) in
  let s = check_for_win s in
  {s with civs = civs; turn = (s.turn + 1)}

(* given an unsatisfied requirement [r], an input event [e], and the game state
 * [s], return a satisfied version of [r] where the parameter comes from parsing
 * [e] using [s].
*)
let parse_event r e (s:State.t) =
  let expected_action = function
    | Tile _ -> "select a tile"
    | HubRole _ -> "select a hub type to build"
    | EntityRole _ -> "select an entity type to produce"
    | Research _ -> "select a research upgrade" in
  match (r,e) with
  | (Tile _,Mouse m) ->
    let f = function
      | Coord.Contained c -> Tile (Some (Mapp.tile_by_pos c s.map))
      | _ -> Tile (None) in
    s.screen_top_left
    |> Coord.Screen.add (Coord.Screen.create ((LTerm_mouse.col m)-20) (LTerm_mouse.row m))
    |> Coord.offset_from_screen
    |> f
  | (HubRole _,Key k) ->
    let menu_for_key =
      try Some (List.find (fun (x:menu) -> x.key = k.code) s.menu)
      with Not_found -> None in
    let r = match menu_for_key with
      | Some (m:Menu.t) ->
        let role_lst = Hub.find_role m.text s.hub_roles in
        let r = match List.length role_lst with
          | 0 -> raise (BadInvariant (
              "game",
              "parse_event",
              "No hub role is associated with the menu item with text: "^m.text))
          | 1 -> List.hd role_lst
          | n -> raise (Critical (
              "game",
              "parse_event",
              "Duplicate rolls \"" ^ m.text ^ "\"exist!" )) in
        r
      | None -> raise (Critical (
          "game",
          "parse_event",
          "No menu item associated with keypress " ^ (LTerm_key.to_string k))) in
    HubRole (Some r)
  | (EntityRole _,Key k) ->
    let menu_for_key =
      try List.find (fun (x:menu) -> x.key = k.code) s.menu
      with Not_found -> raise (Critical (
          "game",
          "parse_event",
          "No menu item associated with keypress " ^ (LTerm_key.to_string k))) in
    let e =
      try Entity.find_role menu_for_key.text s.entity_roles
      with Illegal _ -> raise (Critical (
          "game",
          "parse_event",
          "Entity role \"" ^ menu_for_key.text ^ "\" not found")) in
    EntityRole (Some e)
  | (a,_) -> raise (Illegal ("Please " ^ (expected_action a)))

let is_some = function
  | Some x -> true
  | None   -> false

let is_satisfied r =
  match r with
  | Tile x       -> is_some x
  | HubRole x    -> is_some x
  | EntityRole x -> is_some x
  | Research x   -> is_some x

let rec satisfy_next_req e s = function
  | []   -> raise (BadInvariant (
      "game",
      "satisfy_next_req",
      "All requirements already satisfied!"))
  | h::t ->
    if is_satisfied h
    then h::(satisfy_next_req e s t)
    else (parse_event h e s)::t

let are_all_reqs_satisfied lst =
  List.fold_left (fun a x -> a && (is_satisfied x)) true lst

(* [execute s e c] returns the next state of the game given the current state
 * [s], the input event [e], and the command [c]. *)
let rec execute (s:State.t) e c : State.t =
  match fst c with
  | NoCmd           -> s
  | NextTurn        -> next_turn s
  | Tutorial        -> s
  | Describe str -> (
    let tile = Mapp.tile_by_pos s.selected_tile s.map in
    match str with
    | "tile" -> dispatch_message s (Tile.describe tile) Message.Info
    | "hub" ->
      let hub = Tile.get_hub tile in
      let s' = match hub with
        | Some h -> dispatch_message s (Hub.describe h) Message.Info
        | None -> raise (Illegal "There is no hub on this tile!") in
      s'
    | "entity" ->
      let entity = Tile.get_entity tile in
      let s' = match entity with
        | Some e -> dispatch_message s (Entity.describe e) Message.Info
        | None -> raise (Illegal "There is no entity on this tile!") in
      s'
    | _ -> s)
  | Research        -> s (* TODO *)
  | DisplayResearch -> (* TEST THIS *)
    let key = (
      match List.nth (snd c) 0 with
      | Research x -> (
        match x with
        | Some key -> key
        | _ -> raise (Illegal ""))
      | _ -> raise (Illegal "")) in
    let civ = State.get_current_civ s in
    let research_list = List.assoc key civ.techs in
    let desc = Research.Unlockable.describe_unlocked research_list in
    let s' = dispatch_message s desc Message.Info in
    s'
  | Skip ->
    let tile = Mapp.tile_by_pos s.selected_tile s.map in
    let entity = Tile.get_entity tile in
    let s' = match entity with
      | Some e ->
        let entity = Entity.set_actions 0 e in
        let civ = State.get_current_civ s in
        let new_civ = Civ.replace_entity entity civ in
        State.update_civ s.current_civ new_civ s
      | None -> dispatch_message s "No entity selected!" Message.Illegal in
    s'
  | Move ->
    if are_all_reqs_satisfied (snd c) then
      (* TODO there's a lot of boilerplate just to extract requirements... *)
      let too = match List.nth (snd c) 0 with
        | Tile t -> (match t with
          | Some x -> x
          | None   -> raise (BadInvariant (
            "game",
            "execute",
            "All requirements satisfied for Move but requirement is None")))
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "Move required Tile but got something else")) in
      let from = match List.nth (snd c) 1 with
        | Tile t -> (match t with
          | Some x -> x
          | None   -> raise (BadInvariant (
            "game",
            "execute",
            "All requirements satisfied for Move but requirement is None")))
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "Move required Tile but got something else")) in
      (* TODO: Tile.move_entity doesn't check movement points *)
      let (from',too') = Tile.move_entity too from in
      let map' = s.map |> Mapp.set_tile from' |> Mapp.set_tile too' in
      { s with pending_cmd = None; map = map' }
    else
      let tile = Mapp.tile_by_pos s.selected_tile s.map in
      (match Tile.get_entity tile with
      | Some e ->
        let c' = ((fst c),(Tile (Some tile))::(List.tl (snd c))) in
        dispatch_message
          { s with pending_cmd = Some c' }
          "Select tile to move to"
          Message.Info
      | None -> raise (Illegal "No entity selected!"))
  | Attack          -> s (* TODO *)
  | PlaceHub        ->
    if are_all_reqs_satisfied (snd c) then
      let tile = match List.nth (snd c) 0 with
        | Tile t -> (match t with
          | Some x -> x
          | None   -> raise (BadInvariant (
            "game",
            "execute",
            "All requirements satisfied for PlaceHub but requirement is None")))
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "PlaceHub required Tile but got something else")) in
      let role = match List.nth (snd c) 1 with
        | HubRole r -> (match r with
          | Some x -> x
          | None   -> raise (BadInvariant (
            "game",
            "execute",
            "All requirements satisfied for PlaceHub but requirement is None")))
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "PlaceHub required HubRole but got something else")) in
      let starting_entity = None in (* TODO *)
      let civ = get_current_civ s in
      let hub = Hub.create ~role:role
                            ~production_rate:1
                            ~def:(Hub.get_role_default_defense role)
                            ~pos:(Tile.get_pos tile) in
      let clusters = Cluster.add_hub civ.clusters s.map hub in
      (* TODO: We never use place_hub *)
      (* let t' = Tile.place_hub role starting_entity tile in
      let map' = Mapp.set_tile t' s.map in *)
      let civ = {civ with clusters=clusters} in
      let s = update_civ s.current_civ civ s in
      dispatch_message
        s
        ((Hub.get_role_name role) ^ " now under construction")
        Message.Info
    else
      let t = Mapp.tile_by_pos s.selected_tile s.map in
      let cmd' = ((fst c),(Tile (Some t))::(List.tl (snd c))) in
      dispatch_message
        { s with pending_cmd = Some cmd' }
        "Select hub role to place"
        Message.Info
  | Clear ->
    let tile = Mapp.tile_by_pos s.selected_tile s.map in
    let s' = match Tile.get_entity tile with
      | Some e ->
        (* TODO pretty sure Tile.clear already does all this checking and error handling... *)
        if Tile.needs_clearing tile then
          let tile = Tile.set_terrain tile Tile.Flatland in
          let map = Mapp.set_tile tile s.map in
          {s with map = map}
        else dispatch_message s "No forest to be cleared!" Message.Illegal
      | None ->
        dispatch_message s "No entity to clear this forest!" Message.Illegal in
    s'
  | Produce ->
    (* TODO Produce requires a Hub role and an Entity role, but here we only use
     * the entity role, because the entity production menu only displays the entities
     * that can be produced for the selected hub role, so really we've already
     * eliminated the possibility that we're producing an entity role that's
     * illegal for this hub role and we don't have to check it twice *)
    if are_all_reqs_satisfied (snd c) then
      let role_to_produce = match List.nth (snd c) 1 with
        | EntityRole x -> (
          match x with
          | Some y -> y
          | None -> raise (BadInvariant (
            "game",
            "execute",
            "Produce requirements were satisfied by EntityRole was None")))
        | _ -> raise (BadInvariant (
          "game",
          "execute",
          "Produce requirements satisfied but requirement was not an EntityRole")) in
      let civ = State.get_current_civ s in
      let entity = Entity.create role_to_produce s.selected_tile civ.next_id in
      let civ = {civ with pending_entities = entity::civ.pending_entities} in
      let s' = State.update_civ s.current_civ civ s in
      dispatch_message
        s
        ("One "^(Entity.get_role_name role_to_produce)^" is now in production")
        Message.Info
    else
      let tile = Mapp.tile_by_pos s.selected_tile s.map in
      let hub = match Tile.get_hub tile with
        | Some h -> h
        | None   -> raise (Illegal "No hub selected!") in
      let cmd' = ((fst c),((HubRole (Some (Hub.get_role hub)))::(List.tl (snd c)))) in
      { s with pending_cmd = Some cmd' }
  | AddEntityToHub ->
    if are_all_reqs_satisfied (snd c) then
      let entity = match List.nth (snd c) 0 with
        | Tile x -> begin
          match x with
          | Some y -> begin
            match Tile.get_entity y with
            | Some z -> z
            | None   -> raise (BadInvariant (
                "game",
                "execute",
                "AddEntityToHub requirements were satisfied, but there is no entity on this tile!"))
            end
          | None -> raise (BadInvariant (
              "game",
              "execute",
              "AddEntityToHub requirements were satisfied by first Tile was None"))
          end
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "AddEntityToHub requirements were satisfied but requirement was not a Tile")) in
      let hub = match List.nth (snd c) 1 with
        | Tile x -> begin
            match x with
            | Some y -> begin
                match Tile.get_hub y with
                | Some z -> z
                | None -> raise (BadInvariant (
                    "game",
                    "execute",
                    "AddEntityToHub requirements were satisfied, but there is no entity on this tile!"))
              end
            | None -> raise (BadInvariant (
                "game",
                "execute",
                "AddEntityToHub requirements were satisfied by first Tile was None"))
          end
        | _ -> raise (BadInvariant (
            "game",
            "execute",
            "AddEntityToHub requirements were satisfied but requirement was not a Tile")) in
      let civ' = Civ.add_entity_to_hub entity hub (List.nth s.civs s.current_civ) in
      let s' = State.update_civ s.current_civ civ' s in
      dispatch_message s' "Entity added to hub" Message.Info
    else
      let t = Mapp.tile_by_pos s.selected_tile s.map in
      let s' = match Tile.get_entity t with
      | Some _ ->
        let cmd' = ((fst c),(Tile (Some t))::(List.tl (snd c))) in
        dispatch_message
          { s with pending_cmd = Some cmd' }
          "Select a hub to add the entity to"
          Message.Info
      | None -> raise (Illegal "No entity on this tile!") in
      s'
  | SelectTile | SelectHub | SelectEntity ->
    let (cmd,req_list) = match s.pending_cmd with
      | Some p -> p
      | None -> raise (BadInvariant (
          "game",
          "execute",
          "No pending command found when executing SelectTile")) in
    let req_list' = satisfy_next_req e s req_list in
    if are_all_reqs_satisfied req_list'
    then execute { s with pending_cmd = None } e (cmd,req_list')
    else { s with pending_cmd=Some (cmd,req_list') }

(* [get_next_state s e] is the next state of the game, given the current state
 * [s] and the input event [e] *)
let get_next_state (s:State.t) (e:LTerm_event.t) : State.t = match e with
  (* ------------------------------------------------------------------------- *)
  (* these keys are not affected by the pending command status *)
  | LTerm_event.Key { code = LTerm_key.Up } ->
    { s with screen_top_left =
               Coord.Screen.add s.screen_top_left (Coord.Screen.create 0 (-1)) }
  | LTerm_event.Key { code = LTerm_key.Down } ->
    { s with screen_top_left =
               Coord.Screen.add s.screen_top_left (Coord.Screen.create 0 1) }
  | LTerm_event.Key { code = LTerm_key.Left } ->
    { s with screen_top_left =
               Coord.Screen.add s.screen_top_left (Coord.Screen.create (-2) 0) }
  | LTerm_event.Key { code = LTerm_key.Right } ->
    { s with screen_top_left =
               Coord.Screen.add s.screen_top_left (Coord.Screen.create 2 0) }
  | LTerm_event.Key { code = Char c } when UChar.char_of c = 'q' ->
    { s with is_quit = true }
  (* ------------------------------------------------------------------------ *)
  (* mouse events as well as any key that is not one of the above must check for
   * a pending command *)
  | LTerm_event.Key { code = c } ->
    let f = function
      | Some (m:menu) ->
        let s' = execute s e m.cmd in
        let next_menu = match m.next_menu with
          | NoMenu -> s'.menu
          | StaticMenu m -> m
          | TileMenu f -> f (Mapp.tile_by_pos s'.selected_tile s'.map)
          | BuildHubMenu f -> f s'.hub_roles
          | ProduceEntityMenu f -> (
            match Tile.get_hub (Mapp.tile_by_pos s'.selected_tile s'.map) with
            | Some h -> f h
            | None   -> raise (Illegal "No hub selected!"))
          | NextResearchMenu f ->
            (* The text of the menu item serves to identify the tech tree branch
             * the user selected *)
            f s'.tech_tree m.text in
        { s' with menu = next_menu }
      | None -> s in
    let menu_for_key =
      try Some (List.find (fun (x:menu) -> x.key = c) s.menu)
      with Not_found -> None in
    f menu_for_key
  | LTerm_event.Mouse e ->
    (* let new_msg' = Printf.sprintf "Mouse clicked at (%d,%d)" e.col e.row in *)
    (* state.ctx.messages <- new_msg'::state.ctx.messages; *)
    let f c = match (c,s.pending_cmd) with
      | (Coord.Contained c,Some cmd) ->
        let cmd = Cmd.create Cmd.SelectTile in
        execute s (LTerm_event.Mouse e) cmd
      | (Coord.Contained c,None) ->
        (* let s' = dispatch_message *)
        (*     s *)
        (*     (Printf.sprintf "Selected tile is now %s" (Coord.to_string c)) *)
        (*     Message.Info in *)
        { s with selected_tile = c }
      | (_,_) -> s in
    s.screen_top_left
    |> Coord.Screen.add (Coord.Screen.create ((LTerm_mouse.col e)-20) (LTerm_mouse.row e))
    |> Coord.offset_from_screen
    |> f
  | _ -> s

let rec player_loop ui state_ref =
  let state = !state_ref in
  LTerm_ui.wait ui >>= fun e ->
  let state' =
    try get_next_state state e with
    | Illegal s -> dispatch_message state s Message.Illegal
    | Critical (file,func,err) ->
      failwith (Printf.sprintf "Critical error in %s.ml:%s: %s" file func err)
    | BadInvariant (file,func,err) ->
      failwith (Printf.sprintf "Invariant violation in %s.ml:%s: %s" file func err) in
  if state'.is_quit (* End more gracefully? *)
  then return ()
  else (
    state_ref := state';
    LTerm_ui.draw ui;
    player_loop ui state_ref)

let main () =
  let (s:State.t) = init_state "src/game_data.json" in
  let state_ref = ref s in
  Lazy.force LTerm.stdout >>= fun term ->
  LTerm.enable_mouse term >>= fun () ->
  LTerm_ui.create term (Interface.draw state_ref) >>= fun ui ->
  player_loop ui state_ref >>= fun () ->
  LTerm.disable_mouse term >>= fun () ->
  LTerm_ui.quit ui

let () = Lwt_main.run (main ())
