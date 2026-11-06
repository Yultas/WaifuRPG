class_name PropRule
extends Resource
## How often a biome scatters one prop inside rooms.

@export var prop: PropDef
## Chance per eligible cell.
@export_range(0.0, 1.0, 0.001) var density := 0.02
## 0 = spread uniformly, 1 = only inside vegetation-noise clusters (groves, thickets).
@export_range(0.0, 1.0, 0.01) var clustering := 0.0
