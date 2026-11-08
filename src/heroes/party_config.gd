class_name PartyConfig
extends Resource
## Party composition and swap balance. The party always holds exactly 3 heroes
## (docs/gdd/02_heroes.md); the same HeroDefinition may fill more than one slot
## in the prototype.


@export var heroes: Array[HeroDefinition] = []
## Seconds between two swaps.
@export var swap_cooldown := 1.0
