extends SceneTree
## Deterministic exact rectangular extraction, no pixel art modification.
func _initialize():
 var source:Image=Image.load_from_file('res://assets/terrain/battlefield_tiles_source.png')
 for index in [58,59]:
  var rect:=Rect2i(roundi((index%8)*source.get_width()/8.0),roundi((index>>3)*source.get_height()/8.0),156,156)
  var crop:=source.get_region(rect)
  crop.save_png('res://assets/terrain/used_tile_%d.png'%index)
 source.get_region(Rect2i(359,519,59,33)).save_png('res://assets/terrain/used_stone.png')
 print('Three exact original-pixel rectangles extracted; full source preserved.')
 quit()
