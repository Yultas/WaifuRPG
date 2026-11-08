class_name EnemyRoomSnapshot
extends RefCounted
## One immutable-by-convention frame. Samples are sorted by stable actor id.

var tick := 0
var epoch := 0
var actors: Array[EnemyActorSample] = []


func actor(actor_id: int) -> EnemyActorSample:
	for sample: EnemyActorSample in actors:
		if sample.actor_id == actor_id:
			return sample
	return null
