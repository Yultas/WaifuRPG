class_name DefenseFormula
extends RefCounted
## Converts signed defense to a bounded damage multiplier without a zero denominator.


static func mitigation(defense: float, constant: float = 0.06) -> float:
	var scaled: float = maxf(0.0, constant) * defense
	return clampf(1.0 - scaled / (1.0 + absf(scaled)), 0.0, 2.0)
