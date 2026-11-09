@tool
extends Texture2DArray

# ====================================================
# Texture2DArray, das sich selbst speichern lässt (Terrain: Bodentexturen und Masken).
# Ein zur Laufzeit gebautes Texture2DArray speichert Godot über die Grafikkarte zurück -
# headless gar nicht, das Array wäre nach dem Laden leer. Hier liegen die Bilder selbst in der
# Datei (layer_images), beim Laden entsteht das Array daraus neu.
# ====================================================

@export_storage var layer_images: Array = []: # Image je Ebene, alle gleich groß und gleiches Format
	set(value):
		layer_images = value
		if not value.is_empty():
			create_from_images(value)

func _validate_property(property: Dictionary) -> void:
	if property.name == "_images":
		property.usage &= ~PROPERTY_USAGE_STORAGE
