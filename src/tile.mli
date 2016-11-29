(* TODO: the module type will be the *last* argument to module functions *)
(** the type of a tile *)
type t

(** a tile can have one of these terrain types *)
type terrain = Flatland | Mountain | Forest | Desert

(** Create and return a tile.
  * [terrain] is the terrain type for the tile.
  *)
val create : terrain:terrain -> pos:Coord.t -> t

val describe : t -> string
val describe_terrain : terrain -> string

(** Create a hub and place it on this tile. For descriptions of the named
  * parameters, see hub.mli.
  * [starting_entity] is an entity that will automatically be consumed by the
  *   new hub when it is finished being built, if such an entity exists.
  *   Typically this is the first entity to start construction of the hub.
  *)
val place_hub :
  role : Hub.role ->
  starting_entity : Entity.t option ->
  tile : t ->
  t

(** [move_entity from to] is a 2-tuple [(from',to')] where [from'] is the updated
  * version of [from] and [to'] is the updated version of [to]. The tiles are
  * updated by moving the entity on [to] to [from].
  *)
val move_entity : t -> t -> t*t

(** [get_art_char c t] is the art cell for the absolute screen coordinate [c],
  * which is contained within tile [t]. This is the art cell for the entity on
  * [t]; or if there is no entity, the hub on [t]; or if there is also no hub,
  * the terrain of [t].
  *)
val get_art_char : Coord.Screen.t -> t -> Art.cell option

(* getters and setters *)

val get_terrain : t -> terrain
val set_terrain : t -> terrain -> t

val is_settled : t -> bool
val settle : t -> t
val unsettle : t -> t

val get_hub : t -> Hub.t option
val set_hub : t -> Hub.t option -> t

val get_entity : t -> Entity.t option (* only one entity is allowed per tile *)
val set_entity : t -> Entity.t option -> t

val get_pos : t -> Coord.t

(* terrain property queries *)

(** whether units are allowed on this tile *)
val has_movement_obstruction : t -> bool
(** the number of turns it takes unit to traverse this tile
  *  for tiles where [movementObstruction = true], [costToMove = -1] *)
val cost_to_move : t -> int
(** whether this tile needs to be cleared before it can be settled *)
val needs_clearing : t -> bool
(** whether hubs are allowed on this tile *)
val has_building_restriction : t -> bool
(** whether food hubs are allowed on this tile (e.g. farms) *)
val has_food_restriction : t -> bool
