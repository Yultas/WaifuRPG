class_name GridUtils
extends RefCounted
## Small grid and random helpers shared by the generation steps.


## 4-connected components of the cells where mask != 0. Each component is a list of indices.
static func components(mask: PackedByteArray, size: Vector2i) -> Array[PackedInt32Array]:
	var result: Array[PackedInt32Array] = []
	var seen := PackedByteArray()
	seen.resize(mask.size())
	for start in mask.size():
		if mask[start] == 0 or seen[start] != 0:
			continue
		var comp := PackedInt32Array([start])
		seen[start] = 1
		var head := 0
		while head < comp.size():
			var i := comp[head]
			head += 1
			var x := i % size.x
			@warning_ignore("integer_division")
			var y := i / size.x
			for n: int in [i - 1 if x > 0 else -1, i + 1 if x < size.x - 1 else -1,
					i - size.x if y > 0 else -1, i + size.x if y < size.y - 1 else -1]:
				if n >= 0 and mask[n] != 0 and seen[n] == 0:
					seen[n] = 1
					comp.append(n)
		result.append(comp)
	return result


## Value below which a share q of the values lies.
static func quantile(values: PackedFloat32Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(q * (sorted.size() - 1)), 0, sorted.size() - 1)]


static func shuffled_indices(count: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(count)
	for i in count:
		order[i] = i
	for i in range(count - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	return order


static func make_noise(noise_seed: int, frequency: float, octaves := 3) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = noise_seed
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	return noise
