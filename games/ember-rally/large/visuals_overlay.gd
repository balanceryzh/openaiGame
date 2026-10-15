extends Node2D
## Camera-projected actor status only; no terrain or character pixels draw here.
var game:Node3D
var font:Font
func setup(owner_game:Node3D) -> void:
	game=owner_game;font=load("res://assets/interface.ttf")

func _bar(p:Vector2,width:float,fraction:float,color:Color,height:float=5) -> void:
	draw_rect(Rect2(p-Vector2.ONE,Vector2(width+2,height+2)),Color(0.015,0.025,0.03,0.94))
	draw_rect(Rect2(p,Vector2(width,height)),Color("24312f"))
	draw_rect(Rect2(p,Vector2(width*clampf(fraction,0,1),height)),color)

func _draw() -> void:
	if not is_instance_valid(game) or not game.ready_complete:return
	var logic:Node2D=game.logic
	if logic.state not in ["play","pause","upgrade","win","lose"]:return
	if logic.state=="play":
		var hero:Vector2=game.project_point(logic.hero)
		_bar(hero+Vector2(-27,15),54,logic.hero_health_ratio(),Color("e9755f") if logic.hero_health_ratio()<=0.30 else Color("8bd0a2"),6)
		var ids:Array=logic.visible_enemy_health_ids()
		for index in ids:
			var enemy:Dictionary=logic.enemies[index]
			_bar(game.project_point(enemy.p)+Vector2(-19,-64),38,float(enemy.hp)/float(enemy.max),Color("c17065"))
		for enemy in logic.enemies:
			if not bool(enemy.get("necromancer",false)) or not game.render_view_rect2d.grow(50).has_point(enemy.p):continue
			var label:String=("泥土召唤" if String(enemy.get("summon_mode",""))=="earth" else "唤醒尸骸") if float(enemy.get("summon_phase",0))>0 else "死灵法师"
			draw_string(font,game.project_point(enemy.p)+Vector2(-28,-84),label,HORIZONTAL_ALIGNMENT_LEFT,-1,13,Color("a7e9b8"))
		for actor in logic.defenders():
			if not game.render_view_rect2d.grow(120).has_point(actor.p) or not logic.show_actor_health(actor,"ally"):continue
			var fraction:float=float(actor.hp)/float(actor.max)
			_bar(game.project_point(actor.p)+Vector2(-19,-64),38,fraction,Color("e57f63") if fraction<=0.30 else Color("8ac6a2"))
		for camp in logic.camps:
			if camp.rescued or not camp.get("discovered",false) or not game.render_view_rect2d.grow(80).has_point(camp.p):continue
			var p:Vector2=game.project_point(camp.p)
			var text:String=""
			if camp.get("status","")=="dead":text="残部已阵亡"
			else:
				var alive:int=logic.camp_resistance.living_guards(camp)
				text="反抗中 · 围兵 %d"%alive if alive>0 else "靠近营救"
			draw_string(font,p+Vector2(-58,-86),text,HORIZONTAL_ALIGNMENT_LEFT,-1,14,Color("efdb9b"))
	if logic.get("legions")!=null and logic.state=="play":
		var waves:Array=logic.legions.status(logic.enemies+logic.sleeping_enemies)
		var remaining:int=0
		var final_wave:bool=false
		for wave in waves:
			if not bool(wave.cleared):
				remaining+=int(wave.pending)+int(wave.living)
				final_wave=final_wave or bool(wave.final)
		if remaining>0:
			var message:String=("最终军团" if final_wave else "军团")+" · 剩余 %d"%remaining
			draw_string(font,Vector2(555,63),message,HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color("eac6a3"))
	if game.get("review_region")!="":
		draw_rect(Rect2(18,54,460,30),Color(0.04,0.05,0.07,0.9))
		draw_string(font,Vector2(32,76),"区域布置测试 · "+str(game.review_region),HORIZONTAL_ALIGNMENT_LEFT,-1,18,Color("f8bd68"))

	elif logic.demo and logic.state=="play":
		draw_rect(Rect2(1020,662,242,28),Color(0.04,0.05,0.07,0.78))
		draw_string(font,Vector2(1032,682),"输入演示 · 自动路线",HORIZONTAL_ALIGNMENT_LEFT,-1,16,Color("d4c7a0"))
