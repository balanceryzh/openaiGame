extends RefCounted
## Accepted frame bytes, individual foot anchors and original unequal holds.
static var packets:Dictionary={}
static func packet(kind:String, elapsed:float)->Dictionary:
 if packets.is_empty():
  var data=JSON.parse_string(FileAccess.get_file_as_string("res://assets/approved_walk12/manifest.json"))
  for k in data.units:
   var unit:Dictionary=data.units[k]
   for f in unit.frames:f.texture=load(f.file)
   packets[k]=unit
 if not packets.has(kind):return {}
 var unit:Dictionary=packets[kind]
 var tick:float=fposmod(elapsed*24.0,26.0)
 var edge:=0.0
 for i in unit.frames.size():
  var f:Dictionary=unit.frames[i];edge+=float(f.ticks)
  if tick<edge:return {"frame":f,"index":i,"pixel_scale":unit.pixel_scale}
 return {}
